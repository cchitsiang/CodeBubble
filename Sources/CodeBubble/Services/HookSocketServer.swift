import Foundation
import Network
import os.log
import CodeBubbleCore

private let log = Logger(subsystem: "com.codebubble", category: "HookSocketServer")

/// Listens on a Unix socket for PermissionRequest hook events from Claude Code,
/// forwards them to AppState, and sends back the user's decision.
@MainActor
final class HookSocketServer {
    private let appState: AppState
    private var listener: NWListener?

    /// Internal meta-tools that are safe to auto-approve without user confirmation (matches upstream).
    private static let autoApproveTools: Set<String> = [
        "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskOutput", "TaskStop",
        "TodoRead", "TodoWrite",
        "EnterPlanMode", "ExitPlanMode",
    ]

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        let socketPath = SocketPath.path
        // Clean up stale socket file
        unlink(socketPath)

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        do {
            listener = try NWListener(using: params)
        } catch {
            log.error("Failed to create NWListener: \(error.localizedDescription)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Restrict socket to current user only
                chmod(socketPath, 0o700)
                log.info("HookSocketServer listening on \(socketPath)")
            case .failed(let err):
                log.error("HookSocketServer failed: \(err.localizedDescription)")
            default:
                break
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let path = SocketPath.path
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            unlink(path)
        }
    }

    // MARK: - Connection handling

    private static let maxPayload = 1_048_576  // 1 MB

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveAll(connection: connection, accumulated: Data())
    }

    private func receiveAll(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }
                if error != nil && accumulated.isEmpty && content == nil {
                    connection.cancel()
                    return
                }

                var data = accumulated
                if let content { data.append(content) }

                if data.count > Self.maxPayload {
                    log.warning("Hook payload too large (\(data.count)B), dropping")
                    connection.cancel()
                    return
                }

                if isComplete || error != nil {
                    self.processRequest(data: data, connection: connection)
                } else {
                    self.receiveAll(connection: connection, accumulated: data)
                }
            }
        }
    }

    // MARK: - Request processing

    private func processRequest(data: Data, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            send(connection: connection, data: Data("{}".utf8))
            return
        }

        let eventName = (json["hook_event_name"] as? String) ?? (json["hookEventName"] as? String) ?? ""
        guard eventName == "PermissionRequest" else {
            // We only handle PermissionRequest via hooks; everything else comes from passive monitoring
            send(connection: connection, data: Data("{}".utf8))
            return
        }

        let sessionId = (json["session_id"] as? String) ?? (json["sessionId"] as? String) ?? "default"
        let toolName = (json["tool_name"] as? String) ?? (json["toolName"] as? String) ?? "Tool"
        let toolInput = (json["tool_input"] as? [String: Any]) ?? [:]

        // Auto-approve internal meta-tools without showing UI (matches upstream)
        if Self.autoApproveTools.contains(toolName) {
            let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
            send(connection: connection, data: Data(response.utf8))
            return
        }

        // Auto-approve when session/subagent has bypass permissions
        let permMode = (json["permission_mode"] as? String) ?? (json["permissionMode"] as? String)
        if permMode == "bypassPermissions" || permMode == "acceptEdits" {
            let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
            send(connection: connection, data: Data(response.utf8))
            return
        }

        // Monitor for bridge process disconnect — if the bridge dies (e.g., Claude killed it),
        // clean up the orphaned queue entry so the ApprovalBar/QuestionBar dismisses.
        monitorPeerDisconnect(connection: connection, sessionId: sessionId)

        // AskUserQuestion is a question, not a permission — route to QuestionBar
        if toolName == "AskUserQuestion" {
            var items: [QuestionItem] = []

            // Parse multi-question format: tool_input.questions[]
            if let questions = toolInput["questions"] as? [[String: Any]] {
                for (index, q) in questions.enumerated() {
                    let text = q["question"] as? String ?? "Question"
                    let header = q["header"] as? String
                    var opts: [String]?
                    var descs: [String]?
                    if let dictOpts = q["options"] as? [[String: Any]] {
                        opts = dictOpts.compactMap { $0["label"] as? String }
                        descs = dictOpts.compactMap { $0["description"] as? String }
                        if descs?.allSatisfy({ $0.isEmpty }) == true { descs = nil }
                    }
                    let key = (header?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? header! : nil) ?? "answer_\(index + 1)"
                    items.append(QuestionItem(question: text, header: header, options: opts, descriptions: descs, answerKey: key))
                }
            }

            // Fallback: single question format
            if items.isEmpty {
                let text = (toolInput["question"] as? String) ?? "Question"
                var opts: [String]?
                if let strOpts = toolInput["options"] as? [String] {
                    opts = strOpts
                } else if let dictOpts = toolInput["options"] as? [[String: Any]] {
                    opts = dictOpts.compactMap { $0["label"] as? String }
                }
                items.append(QuestionItem(question: text, header: nil, options: opts, descriptions: nil, answerKey: "answer"))
            }

            Task {
                let responseData = await withCheckedContinuation { continuation in
                    appState.enqueueHookQuestion(
                        sessionId: sessionId,
                        items: items,
                        continuation: continuation
                    )
                }
                self.send(connection: connection, data: responseData)
            }
            return
        }

        Task {
            let responseData = await withCheckedContinuation { continuation in
                appState.enqueueHookApproval(
                    sessionId: sessionId,
                    toolName: toolName,
                    toolInput: toolInput,
                    continuation: continuation
                )
            }
            self.send(connection: connection, data: responseData)
        }
    }

    // MARK: - Peer disconnect monitoring (ported from CodeIsland)

    /// Per-connection state — `responded` flips to true once we've sent the response,
    /// so our own `connection.cancel()` inside `send` does not masquerade as a peer disconnect.
    private final class ConnectionContext { var responded = false }
    private var contexts: [ObjectIdentifier: ConnectionContext] = [:]

    /// Watch for bridge process disconnect. Uses `stateUpdateHandler` transitioning to
    /// `cancelled`/`failed` — NOT EOF on read side (bridge does `shutdown(SHUT_WR)` which
    /// produces EOF on half-close, not a real disconnect).
    private func monitorPeerDisconnect(connection: NWConnection, sessionId: String) {
        let ctx = ConnectionContext()
        contexts[ObjectIdentifier(connection)] = ctx

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .cancelled, .failed:
                    if !ctx.responded {
                        self.appState.handlePeerDisconnect(sessionId: sessionId)
                    }
                    self.contexts.removeValue(forKey: ObjectIdentifier(connection))
                default:
                    break
                }
            }
        }
    }

    private func send(connection: NWConnection, data: Data) {
        // Mark as responded BEFORE cancel() so the disconnect monitor ignores our own teardown.
        if let ctx = contexts[ObjectIdentifier(connection)] {
            ctx.responded = true
        }
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
