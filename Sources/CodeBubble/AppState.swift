import SwiftUI
import os.log
import CodeBubbleCore

private let log = Logger(subsystem: "com.codebubble", category: "AppState")

@MainActor
@Observable
final class AppState {
    var sessions: [String: SessionSnapshot] = [:]
    var activeSessionId: String?
    var surface: IslandSurface = .collapsed
    /// Queue of pending hook-based approvals (interactive). Head item is shown in ApprovalBar.
    var hookApprovalQueue: [HookApproval] = []
    /// Queue of pending AskUserQuestion (interactive). Head item is shown in QuestionBar.
    var hookQuestionQueue: [HookQuestion] = []

    var justCompletedSessionId: String? {
        if case .completionCard(let id) = surface { return id }
        return nil
    }

    /// First-in-line interactive approval (if any).
    var pendingHookApproval: HookApproval? { hookApprovalQueue.first }

    private var cleanupTimer: Timer?
    private var autoCollapseTask: Task<Void, Never>?
    private var completionQueue: [String] = []
    /// Track last observed activity per session to detect fast transitions missed by polling
    private var lastObservedActivity: [String: Date] = [:]
    /// Sessions recently resolved via hook (approve/deny) — suppress JSONL-based approval for 10s
    private var recentlyResolvedApprovals: [String: Date] = [:]
    /// Mouse must enter the panel before auto-collapse is allowed (prevents instant dismiss)
    var completionHasBeenEntered = false
    private var isShowingCompletion: Bool {
        if case .completionCard = surface { return true }
        return false
    }

    var rotatingSessionId: String?
    var rotatingSession: SessionSnapshot? {
        guard let rid = rotatingSessionId else { return nil }
        return sessions[rid]
    }
    private var rotationTimer: Timer?

    // Cached derived state (refreshed by refreshDerivedState after session mutations)
    private(set) var status: AgentStatus = .idle
    private(set) var primarySource: String = "claude"
    private(set) var activeSessionCount: Int = 0
    private(set) var totalSessionCount: Int = 0

    // MARK: - Cleanup Timer

    private func startCleanupTimer() {
        guard cleanupTimer == nil else { return }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupIdleSessions()
            }
        }
    }

    private func cleanupIdleSessions() {
        // With provider-driven polling, session lifecycle is managed by providers:
        // sessions only exist while their process is running. No timeout-based
        // cleanup is needed — providers stop reporting sessions when processes exit,
        // and updateFromProviders() removes them immediately.
        startRotationIfNeeded()
        refreshDerivedState()
    }

    // MARK: - Session Removal

    /// Remove a session and clean up UI state.
    func removeSession(_ sessionId: String) {
        if surface.sessionId == sessionId {
            autoCollapseTask?.cancel()
            if case .completionCard = surface {
                if !showNextPending() {
                    showNextCompletionOrCollapse()
                }
            } else {
                _ = showNextPending()
            }
        }
        sessions.removeValue(forKey: sessionId)
        completionQueue.removeAll { $0 == sessionId }
        if activeSessionId == sessionId {
            activeSessionId = mostActiveSessionId()
        }
        startRotationIfNeeded()
        refreshDerivedState()
    }

    // MARK: - Compact bar mascot rotation

    /// Cached sorted active session IDs — refreshed by refreshActiveIds()
    private var cachedActiveIds: [String] = []

    private func refreshActiveIds() {
        cachedActiveIds = sessions
            .filter { $0.value.status != .idle }
            .sorted { a, b in
                let pa = statusPriority(a.value.status)
                let pb = statusPriority(b.value.status)
                if pa != pb { return pa > pb }
                return a.value.lastActivity > b.value.lastActivity
            }
            .map(\.key)
    }

    /// Higher = more urgent, shown first in rotation
    private func statusPriority(_ status: AgentStatus) -> Int {
        switch status {
        case .waitingForUser: return 4
        case .running:        return 3
        case .thinking:       return 2
        case .idle:           return 0
        }
    }

    private func startRotationIfNeeded() {
        refreshActiveIds()
        if cachedActiveIds.count > 1 {
            if let top = cachedActiveIds.first, top != rotatingSessionId {
                let topStatus = sessions[top]?.status ?? .idle
                let currentStatus = rotatingSessionId.flatMap { sessions[$0]?.status } ?? .idle
                if statusPriority(topStatus) > statusPriority(currentStatus) {
                    rotatingSessionId = top
                }
            }
            if rotatingSessionId == nil || !cachedActiveIds.contains(rotatingSessionId!) {
                rotatingSessionId = cachedActiveIds.first
            }
            if rotationTimer == nil {
                let interval = TimeInterval(max(1, SettingsManager.shared.rotationInterval))
                rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.rotateToNextSession()
                    }
                }
            }
        } else {
            rotationTimer?.invalidate()
            rotationTimer = nil
            rotatingSessionId = nil
            if let active = cachedActiveIds.first,
               activeSessionId != active {
                activeSessionId = active
            }
        }
    }

    private func rotateToNextSession() {
        guard cachedActiveIds.count > 1 else {
            rotatingSessionId = nil
            return
        }
        if let current = rotatingSessionId, let idx = cachedActiveIds.firstIndex(of: current) {
            rotatingSessionId = cachedActiveIds[(idx + 1) % cachedActiveIds.count]
        } else {
            rotatingSessionId = cachedActiveIds.first
        }
    }

    // MARK: - Completion Queue

    private var isShowingInteractive: Bool {
        switch surface {
        case .approvalCard, .questionCard: return true
        default: return false
        }
    }

    private func enqueueCompletion(_ sessionId: String) {
        if completionQueue.contains(sessionId) || justCompletedSessionId == sessionId { return }

        if isShowingCompletion || isShowingInteractive {
            // Don't overwrite approval/question cards — queue for later
            completionQueue.append(sessionId)
        } else {
            showCompletion(sessionId)
        }
    }

    private func showCompletion(_ sessionId: String) {
        doShowCompletion(sessionId)
    }

    private func doShowCompletion(_ sessionId: String) {
        activeSessionId = sessionId
        surface = .completionCard(sessionId: sessionId)
        completionHasBeenEntered = false

        autoCollapseTask?.cancel()
        autoCollapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            showNextCompletionOrCollapse()
        }
    }

    func cancelCompletionQueue() {
        autoCollapseTask?.cancel()
        completionQueue.removeAll()
    }

    private func showNextCompletionOrCollapse() {
        if showNextPending() { return }
        withAnimation(NotchAnimation.close) {
            surface = .collapsed
        }
    }

    // MARK: - Derived State

    var currentTool: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.currentTool
    }

    var toolDescription: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.toolDescription
    }

    var activeDisplayName: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.projectDisplayName ?? id
    }

    var activeModel: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.model
    }

    /// Recompute cached status/source/counts from sessions in a single O(n) pass.
    private func refreshDerivedState() {
        let summary = deriveSessionSummary(from: sessions)
        if status != summary.status { status = summary.status }
        if primarySource != summary.primarySource { primarySource = summary.primarySource }
        if activeSessionCount != summary.activeSessionCount { activeSessionCount = summary.activeSessionCount }
        if totalSessionCount != summary.totalSessionCount { totalSessionCount = summary.totalSessionCount }
    }

    /// After dequeuing, show next pending item or collapse
    @discardableResult
    private func showNextPending() -> Bool {
        if !completionQueue.isEmpty {
            while let next = completionQueue.first {
                completionQueue.removeFirst()
                if sessions[next] != nil {
                    withAnimation(NotchAnimation.pop) { doShowCompletion(next) }
                    return true
                }
            }
            return false
        }
        return false
    }

    /// Find the most recently active non-idle session
    private func mostActiveSessionId() -> String? {
        sessions.max { a, b in
            let pa = statusPriority(a.value.status)
            let pb = statusPriority(b.value.status)
            if pa != pb { return pa < pb }
            return a.value.lastActivity < b.value.lastActivity
        }?.key
    }

    // MARK: - Hook-Based Approvals (Interactive)

    /// Enqueue a new approval request from the hook socket.
    /// Called by HookSocketServer when Claude Code fires a PermissionRequest hook.
    func enqueueHookApproval(
        sessionId: String,
        toolName: String,
        toolInput: [String: Any],
        continuation: CheckedContinuation<Data, Never>
    ) {
        // Drain stale approvals for this session — if Claude fires a new hook,
        // any previous pending hooks for the same session are obsolete (Claude
        // already moved past them, possibly via terminal approval or timeout).
        let allowData = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8)
        hookApprovalQueue.removeAll { item in
            guard item.sessionId == sessionId else { return false }
            item.continuation.resume(returning: allowData)
            return true
        }

        let approval = HookApproval(
            sessionId: sessionId,
            toolName: toolName,
            toolInput: toolInput,
            continuation: continuation
        )
        hookApprovalQueue.append(approval)

        // Surface approval card and update active session
        surface = .approvalCard(sessionId: sessionId)
        activeSessionId = sessionId
        SoundManager.shared.handleEvent("PermissionRequest")

        // Reflect in session state
        sessions[sessionId]?.status = .waitingForUser
        sessions[sessionId]?.pendingApprovalTool = toolName
        sessions[sessionId]?.pendingApprovalDetail = Self.describePendingTool(name: toolName, input: toolInput)
        refreshDerivedState()
    }

    /// Approve the head of the queue (once). Sends behavior=allow back to Claude Code.
    func approveHookApproval(always: Bool = false) {
        guard !hookApprovalQueue.isEmpty else { return }
        let head = hookApprovalQueue.removeFirst()

        let responseData: Data
        if always {
            // Match upstream CodeIsland format exactly
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedPermissions": [[
                            "type": "addRules",
                            "rules": [["toolName": head.toolName, "ruleContent": "*"]],
                            "behavior": "allow",
                            "destination": "session"
                        ]]
                    ] as [String: Any]
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            responseData = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8)
        }

        head.continuation.resume(returning: responseData)
        clearPendingApproval(for: head.sessionId, approved: true)
        showNextApprovalOrCollapse()
    }

    /// Deny the head of the queue.
    func denyHookApproval() {
        guard !hookApprovalQueue.isEmpty else { return }
        let head = hookApprovalQueue.removeFirst()

        let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
        head.continuation.resume(returning: Data(response.utf8))

        clearPendingApproval(for: head.sessionId, approved: false)
        showNextApprovalOrCollapse()
    }

    private func clearPendingApproval(for sessionId: String, approved: Bool) {
        // Only clear session's pending info if no other approval exists for this session
        let stillPending = hookApprovalQueue.contains { $0.sessionId == sessionId }
        if !stillPending {
            sessions[sessionId]?.pendingApprovalTool = nil
            sessions[sessionId]?.pendingApprovalDetail = nil
            // Immediately transition status (CodeIsland approach) so the UI doesn't
            // show stale approval state while JSONL catches up with tool_result.
            sessions[sessionId]?.status = approved ? .running : .idle
            // Suppress JSONL-based re-detection until the next meaningful JSONL update
            recentlyResolvedApprovals[sessionId] = Date()
        }
    }

    private func showNextApprovalOrCollapse() {
        if let next = hookApprovalQueue.first {
            surface = .approvalCard(sessionId: next.sessionId)
            activeSessionId = next.sessionId
        } else if let next = hookQuestionQueue.first {
            surface = .questionCard(sessionId: next.sessionId)
            activeSessionId = next.sessionId
        } else if showNextPending() {
            // completion card shown
        } else {
            withAnimation(NotchAnimation.close) {
                surface = .collapsed
            }
        }
        refreshDerivedState()
    }

    /// Build a short human-readable description of a tool invocation for the approval UI.
    private static func describePendingTool(name: String, input: [String: Any]) -> String? {
        switch name {
        case "Bash":
            return input["command"] as? String
        case "Edit", "Write", "Read", "NotebookEdit":
            return input["file_path"] as? String
        case "Grep":
            if let pattern = input["pattern"] as? String {
                if let path = input["path"] as? String {
                    return "\(pattern)  in  \(path)"
                }
                return pattern
            }
        case "Glob":
            return input["pattern"] as? String
        case "WebFetch":
            return input["url"] as? String
        case "WebSearch":
            return input["query"] as? String
        case "AskUserQuestion":
            return input["question"] as? String
        default:
            for key in input.keys.sorted() {
                if let v = input[key] as? String, !v.isEmpty { return v }
            }
        }
        return nil
    }

    // MARK: - Peer Disconnect (bridge died / Claude killed hook)

    /// Called when the bridge socket disconnects before we sent a response.
    /// The bridge exited (e.g., Claude timed it out or user Ctrl-C'd) — clean up
    /// orphaned queue entries so the ApprovalBar/QuestionBar dismisses.
    func handlePeerDisconnect(sessionId: String) {
        // Drain approvals for this session
        let denyData = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
        hookApprovalQueue.removeAll { item in
            guard item.sessionId == sessionId else { return false }
            item.continuation.resume(returning: denyData)
            return true
        }
        // Drain questions for this session
        hookQuestionQueue.removeAll { item in
            guard item.sessionId == sessionId else { return false }
            item.continuation.resume(returning: denyData)
            return true
        }

        sessions[sessionId]?.pendingApprovalTool = nil
        sessions[sessionId]?.pendingApprovalDetail = nil
        recentlyResolvedApprovals[sessionId] = Date()

        // Dismiss the card if it was showing for this session
        if case .approvalCard(let sid) = surface, sid == sessionId {
            showNextApprovalOrCollapse()
        } else if case .questionCard(let sid) = surface, sid == sessionId {
            showNextApprovalOrCollapse()
        }
        refreshDerivedState()
    }

    // MARK: - Hook-Based Questions (AskUserQuestion)

    /// First pending question (if any).
    var pendingHookQuestion: HookQuestion? { hookQuestionQueue.first }

    /// Enqueue a question batch from the AskUserQuestion hook.
    func enqueueHookQuestion(
        sessionId: String,
        items: [QuestionItem],
        continuation: CheckedContinuation<Data, Never>
    ) {
        // Drain stale questions for this session
        let denyData = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
        hookQuestionQueue.removeAll { item in
            guard item.sessionId == sessionId else { return false }
            item.continuation.resume(returning: denyData)
            return true
        }

        let q = HookQuestion(sessionId: sessionId, items: items, continuation: continuation)
        hookQuestionQueue.append(q)

        surface = .questionCard(sessionId: sessionId)
        activeSessionId = sessionId
        SoundManager.shared.handleEvent("PermissionRequest")
        sessions[sessionId]?.status = .waitingForUser
        refreshDerivedState()
    }

    /// Answer the head question with collected answers (key → value).
    func answerHookQuestion(_ answers: [String: String]) {
        guard !hookQuestionQueue.isEmpty else { return }
        let head = hookQuestionQueue.removeFirst()

        let obj: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "allow",
                    "updatedInput": ["answers": answers]
                ] as [String: Any]
            ] as [String: Any]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        head.continuation.resume(returning: data)

        // Immediately transition (CodeIsland: status = .processing after answer)
        recentlyResolvedApprovals[head.sessionId] = Date()
        sessions[head.sessionId]?.status = .thinking
        sessions[head.sessionId]?.pendingApprovalTool = nil
        sessions[head.sessionId]?.pendingApprovalDetail = nil

        // Show next pending item from any queue (CodeIsland's showNextPending pattern)
        if let next = hookApprovalQueue.first {
            surface = .approvalCard(sessionId: next.sessionId)
            activeSessionId = next.sessionId
        } else if let next = hookQuestionQueue.first {
            surface = .questionCard(sessionId: next.sessionId)
            activeSessionId = next.sessionId
        } else if showNextPending() {
            // completion card shown
        } else {
            surface = .collapsed
        }
        refreshDerivedState()
    }

    /// Skip the head question (sends deny/empty response).
    func skipHookQuestion() {
        guard !hookQuestionQueue.isEmpty else { return }
        let head = hookQuestionQueue.removeFirst()

        let data = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
        head.continuation.resume(returning: data)
        recentlyResolvedApprovals[head.sessionId] = Date()
        sessions[head.sessionId]?.status = .thinking
        sessions[head.sessionId]?.pendingApprovalTool = nil
        sessions[head.sessionId]?.pendingApprovalDetail = nil

        if let next = hookQuestionQueue.first {
            surface = .questionCard(sessionId: next.sessionId)
            activeSessionId = next.sessionId
        } else {
            surface = .collapsed
        }
        refreshDerivedState()
    }

    // MARK: - Provider-Driven Updates

    /// Called by SessionMonitor on each poll cycle with fresh provider data.
    func updateFromProviders(_ agentSessions: [AgentSession]) {
        var updatedIds: Set<String> = []

        for session in agentSessions {
            updatedIds.insert(session.id)

            let isNew = sessions[session.id] == nil
            if isNew {
                sessions[session.id] = SessionSnapshot(startTime: session.lastActivity)
                SoundManager.shared.handleEvent("SessionStart")
            }

            let status: AgentStatus
            switch session.activity {
            case .thinking: status = .thinking
            case .executingTool: status = .running
            case .waitingForUser: status = .waitingForUser
            case .idle: status = .idle
            }

            // Detect transitions to idle (completion) for notification
            let previousStatus = sessions[session.id]?.status
            let wasActive = previousStatus != nil && previousStatus != .idle

            // If hook has a pending approval for this session, it's authoritative —
            // don't let provider polling overwrite the waiting state or pending tool info.
            let hasHookApproval = hookApprovalQueue.contains { $0.sessionId == session.id }
            let hasHookQuestion = hookQuestionQueue.contains { $0.sessionId == session.id }

            // After hook approve/deny, suppress JSONL re-detection for 10s while
            // Claude runs the tool and writes tool_result (CodeIsland approach:
            // immediately set .running on approve, let next JSONL update correct it).
            let recentlyResolved: Bool
            if let resolvedAt = recentlyResolvedApprovals[session.id] {
                if Date().timeIntervalSince(resolvedAt) < 10 {
                    recentlyResolved = true
                } else {
                    recentlyResolvedApprovals.removeValue(forKey: session.id)
                    recentlyResolved = false
                }
            } else {
                recentlyResolved = false
            }

            if hasHookApproval || hasHookQuestion {
                sessions[session.id]?.status = .waitingForUser
            } else if recentlyResolved && status == .waitingForUser {
                // Suppress: JSONL still shows old tool_use but we already resolved it
            } else {
                sessions[session.id]?.status = status
                sessions[session.id]?.pendingApprovalTool = session.pendingApprovalTool
                sessions[session.id]?.pendingApprovalDetail = session.pendingApprovalDetail
            }

            sessions[session.id]?.currentTool = session.currentTool
            sessions[session.id]?.toolDescription = session.toolDescription
            sessions[session.id]?.lastActivity = session.lastActivity
            sessions[session.id]?.cwd = session.cwd
            sessions[session.id]?.model = session.model
            sessions[session.id]?.gitBranch = session.gitBranch
            sessions[session.id]?.source = session.source

            if let prompt = session.lastUserPrompt {
                sessions[session.id]?.lastUserPrompt = prompt
            }
            if let msg = session.lastAssistantMessage {
                sessions[session.id]?.lastAssistantMessage = msg
            }

            // Play sound on transition into waitingForUser (JSONL-detected).
            // We deliberately do NOT auto-surface the approval card here — the hook
            // (via enqueueHookApproval) is authoritative for popping up the approval
            // UI. If no hook is installed, the user can tap the card in the session
            // list to see the read-only ApprovalBar.
            let becameWaiting = previousStatus != .waitingForUser && status == .waitingForUser
            if becameWaiting, session.pendingApprovalTool != nil {
                SoundManager.shared.handleEvent("PermissionRequest")
            }

            // Enqueue completion card when session transitions to idle.
            // Also detect fast completions missed by polling: if status is idle but
            // lastActivity changed since last observation, Claude did work between polls.
            let prevActivity = lastObservedActivity[session.id]
            let activityChanged = prevActivity == nil || session.lastActivity > prevActivity!
            lastObservedActivity[session.id] = session.lastActivity

            let shouldComplete = (status == .idle && activityChanged && !isNew) || (wasActive && status == .idle)
            if shouldComplete {
                // If the "idle" session is actually a text question (? heuristic),
                // show approval card with "Answer in Terminal" instead of completion.
                // The 20s delay in determineActivity is for avoiding streaming flicker,
                // but at completion time streaming is already done.
                if !HookInstaller.isInstalled() && session.pendingApprovalTool == "AskUserQuestion" {
                    sessions[session.id]?.status = .waitingForUser
                    sessions[session.id]?.pendingApprovalTool = session.pendingApprovalTool
                    sessions[session.id]?.pendingApprovalDetail = session.pendingApprovalDetail
                    if !isShowingInteractive {
                        surface = .approvalCard(sessionId: session.id)
                        activeSessionId = session.id
                        SoundManager.shared.handleEvent("PermissionRequest")
                    }
                } else if status == .waitingForUser && session.pendingApprovalTool != nil {
                    // Tool-based waiting detected at completion boundary
                } else {
                    enqueueCompletion(session.id)
                }
            }
        }

        // Remove sessions no longer reported by any provider.
        // Providers only return sessions with live processes, so if a session
        // disappears from the provider list, the process has exited.
        let staleIds = Set(sessions.keys).subtracting(updatedIds)
        for id in staleIds {
            sessions.removeValue(forKey: id)
        }

        // Update active session
        if activeSessionId == nil || sessions[activeSessionId ?? ""] == nil {
            activeSessionId = sessions.keys.sorted { a, b in
                (sessions[a]?.lastActivity ?? .distantPast) > (sessions[b]?.lastActivity ?? .distantPast)
            }.first
        }

        // Surface the approval card whenever any session is pending approval.
        // If currently on approvalCard for a session that's no longer waiting, revert.
        reconcileApprovalSurface()

        startRotationIfNeeded()
        refreshDerivedState()
    }

    /// Session ID with highest priority pending approval.
    /// Hook-based queue is authoritative (real interactive approval); falls back
    /// to JSONL-detected waitingForUser sessions (read-only).
    var pendingApprovalSessionId: String? {
        // Hook queue is authoritative — always check first
        if let head = hookApprovalQueue.first {
            return head.sessionId
        }
        // When hooks are installed, don't show passive "Approve in Terminal" —
        // the hook will fire and show the interactive ApprovalBar.
        // Passive fallback is only for setups without hooks.
        if HookInstaller.isInstalled() {
            return nil
        }
        return sessions
            .filter { $0.value.status == .waitingForUser && $0.value.pendingApprovalTool != nil }
            .max { a, b in a.value.lastActivity < b.value.lastActivity }?
            .key
    }

    /// If currently showing an approvalCard for a session that's no longer waiting,
    /// move to the next pending approval or collapse. Does NOT auto-surface new
    /// approval cards — that happens only on transition into waitingForUser.
    private func reconcileApprovalSurface() {
        guard case .approvalCard(let shownId) = surface else { return }
        if sessions[shownId]?.status != .waitingForUser
            || sessions[shownId]?.pendingApprovalTool == nil {
            if let next = pendingApprovalSessionId {
                surface = .approvalCard(sessionId: next)
                activeSessionId = next
            } else {
                surface = .collapsed
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        startCleanupTimer()
    }

    deinit {
        MainActor.assumeIsolated {
            rotationTimer?.invalidate()
            cleanupTimer?.invalidate()
        }
    }
}
