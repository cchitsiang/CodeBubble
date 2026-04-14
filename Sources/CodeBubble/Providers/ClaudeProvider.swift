import Foundation
import os.log

private let log = Logger(subsystem: "com.codebubble", category: "ClaudeProvider")

// MARK: - Data Model

struct ClaudeContentBlock {
    let type: String       // "text", "tool_use", "tool_result", "thinking"
    let text: String?
    let toolName: String?  // for tool_use (from "name" field)
    let toolId: String?    // for tool_use "id" / tool_result "tool_use_id"
    let toolInput: [String: Any]?  // for tool_use (from "input" field) — needed for Bash permission check
}

struct ClaudeMessage {
    let role: String
    let model: String?
    let contentBlocks: [ClaudeContentBlock]?
    let stopReason: String?
}

struct ClaudeJSONLEntry {
    let type: String       // "user", "assistant"
    let sessionId: String?
    let timestamp: Date
    let cwd: String?
    let gitBranch: String?
    let version: String?
    let permissionMode: String?  // "default", "bypassPermissions", "plan", etc.
    let message: ClaudeMessage?

    // MARK: - Parsing

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseTimestamp(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }

    static func parse(_ line: String) -> ClaudeJSONLEntry? {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        // Parse permission-mode entries (carries the session's permissionMode)
        if type == "permission-mode" {
            let pm = json["permissionMode"] as? String
            return ClaudeJSONLEntry(
                type: type, sessionId: json["sessionId"] as? String,
                timestamp: Date(), cwd: nil, gitBranch: nil,
                version: nil, permissionMode: pm, message: nil
            )
        }

        // Skip non-meaningful types
        guard type == "user" || type == "assistant" else {
            return nil
        }

        guard let timestampStr = json["timestamp"] as? String,
              let timestamp = parseTimestamp(timestampStr) else {
            return nil
        }

        let sessionId = json["sessionId"] as? String
        let cwd = json["cwd"] as? String
        let gitBranch = json["gitBranch"] as? String
        let permissionMode = json["permissionMode"] as? String
        let version = json["version"] as? String

        var message: ClaudeMessage?
        if let msgDict = json["message"] as? [String: Any] {
            let role = msgDict["role"] as? String ?? type
            let model = msgDict["model"] as? String
            let stopReason = msgDict["stop_reason"] as? String

            var contentBlocks: [ClaudeContentBlock]?
            if let contentArray = msgDict["content"] as? [[String: Any]] {
                contentBlocks = contentArray.compactMap { block in
                    guard let blockType = block["type"] as? String else { return nil }
                    let text = block["text"] as? String
                    let toolName = block["name"] as? String
                    let toolId = block["id"] as? String ?? block["tool_use_id"] as? String
                    let toolInput = block["input"] as? [String: Any]
                    return ClaudeContentBlock(
                        type: blockType,
                        text: text,
                        toolName: toolName,
                        toolId: toolId,
                        toolInput: toolInput
                    )
                }
            } else if let contentStr = msgDict["content"] as? String {
                contentBlocks = [ClaudeContentBlock(type: "text", text: contentStr, toolName: nil, toolId: nil, toolInput: nil)]
            }

            message = ClaudeMessage(
                role: role,
                model: model,
                contentBlocks: contentBlocks,
                stopReason: stopReason
            )
        }

        return ClaudeJSONLEntry(
            type: type,
            sessionId: sessionId,
            timestamp: timestamp,
            cwd: cwd,
            gitBranch: gitBranch,
            version: version,
            permissionMode: permissionMode,
            message: message
        )
    }
}

// MARK: - ClaudeProvider

final class ClaudeProvider: SessionProvider {
    let source = "claude"

    /// Override for the base config directory (defaults to ~/.claude).
    private let configDir: String

    /// Cached permission checker — reloaded periodically.
    private var permissionChecker: ClaudePermissionChecker
    private var lastPermissionLoad: Date = .distantPast

    /// Cache: JSONL file path → session permissionMode (read from file header once).
    private var sessionPermissionModes: [String: String] = [:]

    /// Cache: PID → terminal bundle ID (detected from process tree once).
    private var pidTerminalCache: [pid_t: String] = [:]

    init(configDir: String? = nil) {
        if let dir = configDir {
            self.configDir = dir
        } else if let envDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            self.configDir = envDir
        } else {
            self.configDir = NSHomeDirectory() + "/.claude"
        }
        self.permissionChecker = ClaudePermissionChecker.load(from: self.configDir)
    }

    /// Reload permissions from settings.json at most every 10 seconds.
    private func refreshPermissionsIfStale() {
        if Date().timeIntervalSince(lastPermissionLoad) > 10 {
            permissionChecker = ClaudePermissionChecker.load(from: configDir)
            lastPermissionLoad = Date()
        }
    }

    func discoverSessions() -> [AgentSession] {
        let fm = FileManager.default

        // Refresh permission settings if stale
        refreshPermissionsIfStale()

        // Step 1: Find running Claude processes via PID files + process table scan.
        // Only sessions with a live process are shown (c9watch approach).
        let runningSessions = discoverRunningSessions(fm: fm)
        guard !runningSessions.isEmpty else { return [] }

        // Step 2: For each running session, find and parse its JSONL file
        let projectsDir = configDir + "/projects"
        let now = Date()
        var results: [AgentSession] = []

        // Build a lookup: sessionId → JSONL path
        var sessionPaths: [String: String] = [:]
        if let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) {
            for projectDir in projectDirs {
                let projectPath = projectsDir + "/" + projectDir
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { continue }
                guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }
                for file in files {
                    guard file.hasSuffix(".jsonl"), !file.hasPrefix("agent-") else { continue }
                    let sessionId = String(file.dropLast(6))
                    if runningSessions.contains(sessionId) {
                        sessionPaths[sessionId] = projectPath + "/" + file
                    }
                }
            }
        }

        for (sessionId, filePath) in sessionPaths {
            let entries = readRecentEntries(from: filePath, count: 20, fm: fm)
            guard !entries.isEmpty else {
                log.warning("No parseable entries for session \(sessionId)")
                continue
            }

            // Check file-level permission mode (from header)
            let filePermMode = sessionPermissionMode(forFile: filePath)

            let activity = ClaudeProvider.determineActivity(
                from: entries,
                permissionChecker: permissionChecker,
                sessionPermissionMode: filePermMode,
                now: now
            )
            let lastEntry = entries.last!
            let cwd = entries.last(where: { $0.cwd != nil })?.cwd
            let gitBranch = entries.last(where: { $0.gitBranch != nil })?.gitBranch
            let model = entries.last(where: {
                $0.type == "assistant" && $0.message?.model != nil
            })?.message?.model

            let lastUserPrompt = entries.last(where: { $0.type == "user" })
                .flatMap { entry -> String? in
                    guard let blocks = entry.message?.contentBlocks else { return nil }
                    return blocks.compactMap { $0.text }.joined(separator: " ")
                }

            let lastAssistantMessage = entries.last(where: { $0.type == "assistant" })
                .flatMap { entry -> String? in
                    guard let blocks = entry.message?.contentBlocks else { return nil }
                    return blocks.filter { $0.type == "text" }.compactMap { $0.text }.joined(separator: " ")
                }

            // If main session is executing Agent/Task and hooks are NOT installed,
            // check subagent JSONL for pending approval (passive fallback).
            // When hooks ARE installed, subagent approvals are auto-approved via agent_id.
            var effectiveActivity = activity
            var subagentPendingTool: String?
            var subagentPendingDetail: String?
            let mainBypass = (filePermMode == "bypassPermissions" || filePermMode == "acceptEdits")
            if !mainBypass, case .executingTool(let toolName) = activity, toolName == "Agent" || toolName == "Task" {
                let subagentDir = (filePath as NSString).deletingLastPathComponent + "/" + sessionId + "/subagents"
                if let sub = checkSubagentForPendingApproval(dir: subagentDir, fm: fm, now: now) {
                    effectiveActivity = .waitingForUser
                    subagentPendingTool = sub.tool
                    subagentPendingDetail = sub.detail
                }
            }

            var currentTool: String?
            if case .executingTool(let name) = effectiveActivity {
                currentTool = name
            }

            // Extract pending tool info for approval/question UI
            var pendingTool: String?
            var pendingDetail: String?
            if let lastMsg = entries.last(where: { $0.type == "assistant" })?.message {
                if activity == .waitingForUser, lastMsg.stopReason == "tool_use",
                   let lastToolUse = lastMsg.contentBlocks?.last(where: { $0.type == "tool_use" }) {
                    // Tool-based waiting (permission or AskUserQuestion)
                    pendingTool = lastToolUse.toolName
                    pendingDetail = Self.describeToolInput(toolName: lastToolUse.toolName, input: lastToolUse.toolInput)
                } else if lastMsg.stopReason == "end_turn", Self.isTextAskingQuestion(lastMsg) {
                    // Text-based question (? heuristic) — passive fallback for app restart.
                    let lastText = lastMsg.contentBlocks?
                        .last(where: { $0.type == "text" })?.text?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    pendingTool = "AskUserQuestion"
                    let lines = lastText.components(separatedBy: "\n")
                    pendingDetail = lines.first(where: {
                        let t = $0.trimmingCharacters(in: .whitespaces)
                        return t.hasSuffix("?") || t.hasSuffix("?)")
                    })?.trimmingCharacters(in: .whitespaces)
                }
            }

            // Override with subagent pending info if available
            if let subTool = subagentPendingTool {
                pendingTool = subTool
                pendingDetail = subagentPendingDetail
            }

            // Detect terminal app from process tree
            let termBundleId = sessionPidMap[sessionId].flatMap { detectTerminalBundleId(for: $0) }

            results.append(AgentSession(
                id: sessionId,
                source: source,
                cwd: cwd,
                model: model,
                gitBranch: gitBranch,
                activity: effectiveActivity,
                lastActivity: lastEntry.timestamp,
                lastUserPrompt: lastUserPrompt,
                lastAssistantMessage: lastAssistantMessage,
                currentTool: currentTool,
                toolDescription: nil,
                terminalBundleId: termBundleId,
                pendingApprovalTool: pendingTool,
                pendingApprovalDetail: pendingDetail
            ))
        }

        return results
    }

    // MARK: - Terminal Detection

    /// Detect the terminal app by walking the process tree from a Claude PID.
    /// Caches the result per PID.
    private func detectTerminalBundleId(for pid: pid_t) -> String? {
        if let cached = pidTerminalCache[pid] { return cached }

        var p = pid
        for _ in 0..<6 {
            let pipe = Pipe()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/ps")
            proc.arguments = ["-o", "ppid=,comm=", "-p", "\(p)"]
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do { try proc.run() } catch { break }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { break }

            let parts = output.split(separator: " ", maxSplits: 1)
            guard let ppid = parts.first.flatMap({ pid_t($0) }) else { break }
            let comm = parts.count > 1 ? String(parts[1]) : ""

            // Check if parent path contains a .app bundle
            if comm.contains(".app/") {
                // Extract /path/to/Foo.app
                if let range = comm.range(of: ".app/") ?? comm.range(of: ".app") {
                    let appPath = String(comm[comm.startIndex...range.lowerBound]) + "app"
                    if let bundle = Bundle(path: appPath), let bid = bundle.bundleIdentifier {
                        pidTerminalCache[pid] = bid
                        return bid
                    }
                }
            }
            p = ppid
            if ppid <= 1 { break }
        }
        return nil
    }

    // MARK: - Subagent Approval Detection

    private struct SubagentPending {
        let tool: String
        let detail: String?
    }

    /// Check the most recently modified subagent JSONL for a pending tool_use that needs approval.
    private func checkSubagentForPendingApproval(dir: String, fm: FileManager, now: Date) -> SubagentPending? {
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }

        // Find the most recently modified agent-*.jsonl
        var latestPath: String?
        var latestMtime: Date = .distantPast
        for file in files {
            guard file.hasPrefix("agent-"), file.hasSuffix(".jsonl") else { continue }
            let path = dir + "/" + file
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date, mtime > latestMtime {
                latestMtime = mtime
                latestPath = path
            }
        }

        guard let path = latestPath else { return nil }

        // Check subagent's permissionMode — if bypass, all tools are auto-approved
        let subPermMode = sessionPermissionMode(forFile: path)
        if subPermMode == "bypassPermissions" || subPermMode == "acceptEdits" {
            return nil
        }

        // Read last few entries — also check inline permissionMode
        let entries = readRecentEntries(from: path, count: 5, fm: fm)
        let entryMode = entries.last(where: { $0.permissionMode != nil })?.permissionMode
        if entryMode == "bypassPermissions" || entryMode == "acceptEdits" {
            return nil
        }

        guard let last = entries.last, last.type == "assistant",
              let msg = last.message, msg.stopReason == "tool_use" else { return nil }

        // Check if any pending tool needs approval
        let toolUses = msg.contentBlocks?.filter { $0.type == "tool_use" } ?? []
        let needsApproval = toolUses.contains { block in
            guard let name = block.toolName else { return false }
            return !permissionChecker.isAutoApproved(tool: name, input: block.toolInput)
        }

        guard needsApproval, let lastTool = toolUses.last else { return nil }
        return SubagentPending(
            tool: lastTool.toolName ?? "Tool",
            detail: Self.describeToolInput(toolName: lastTool.toolName, input: lastTool.toolInput)
        )
    }

    // MARK: - Text Question Detection

    /// Detect if an assistant message is asking the user a text-based question.
    /// Checks if the last text block contains a `?` in its final lines.
    /// Safe because this is only called for `stop_reason == "end_turn"` entries
    /// that are > 20 seconds old (streaming is finished, process is alive).
    static func isTextAskingQuestion(_ message: ClaudeMessage) -> Bool {
        guard let text = message.contentBlocks?
            .last(where: { $0.type == "text" })?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return false }

        // Check if any of the last 5 non-empty lines contains '?'
        // Covers: question at end, question + options, question + alternative suggestion
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(5)
        return tail.contains { $0.contains("?") }
    }

    // MARK: - Session Permission Mode

    /// Read the permissionMode from the head of a JSONL file.
    /// Claude writes a `{"type":"permission-mode","permissionMode":"..."}` entry
    /// near the top of the file. We cache the result per file path.
    private func sessionPermissionMode(forFile path: String) -> String? {
        if let cached = sessionPermissionModes[path] { return cached }

        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        // Read first 8KB — the permission-mode entry is in the first few lines
        let headData = handle.readData(ofLength: 8192)
        guard let text = String(data: headData, encoding: .utf8) else { return nil }

        for line in text.components(separatedBy: "\n").prefix(20) {
            guard let entry = ClaudeJSONLEntry.parse(line),
                  entry.type == "permission-mode",
                  let mode = entry.permissionMode else { continue }
            sessionPermissionModes[path] = mode
            return mode
        }

        // Also check if entries carry permissionMode inline
        for line in text.components(separatedBy: "\n").prefix(20) {
            guard let entry = ClaudeJSONLEntry.parse(line),
                  let mode = entry.permissionMode else { continue }
            sessionPermissionModes[path] = mode
            return mode
        }

        return nil
    }

    // MARK: - Tool Input Description

    /// Build a short human-readable description of a tool invocation for the approval UI.
    static func describeToolInput(toolName: String?, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        switch toolName {
        case "Bash":
            if let cmd = input["command"] as? String { return cmd }
        case "Edit", "Write", "Read", "NotebookEdit":
            if let fp = input["file_path"] as? String { return fp }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                if let path = input["path"] as? String {
                    return "\(pattern)  in  \(path)"
                }
                return pattern
            }
        case "Glob":
            if let pattern = input["pattern"] as? String { return pattern }
        case "WebFetch":
            if let url = input["url"] as? String { return url }
        case "WebSearch":
            if let query = input["query"] as? String { return query }
        case "AskUserQuestion":
            if let question = input["question"] as? String { return question }
            if let questions = input["questions"] as? [[String: Any]],
               let first = questions.first?["question"] as? String { return first }
        default:
            break
        }
        // Fallback: first string value
        for key in input.keys.sorted() {
            if let v = input[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    // MARK: - Status Determination

    /// Determine the current activity from the last ~20 JSONL entries.
    /// Uses a permission checker (c9watch approach) to determine if a pending
    /// tool_use needs user approval or is auto-approved.
    static func determineActivity(
        from entries: [ClaudeJSONLEntry],
        permissionChecker: ClaudePermissionChecker = ClaudePermissionChecker(patterns: []),
        sessionPermissionMode: String? = nil,
        now: Date = Date()
    ) -> SessionActivity {
        guard let lastEntry = entries.last else {
            return .idle
        }

        _ = now  // kept for signature compatibility; process liveness is our staleness check

        switch lastEntry.type {
        case "user":
            // User just sent a message (or tool_result). Since we only show sessions
            // with live processes, trust the process — Claude is still working on it
            // regardless of age.
            return .thinking

        case "assistant":
            guard let message = lastEntry.message else {
                return .idle
            }

            switch message.stopReason {
            case "tool_use":
                // Find pending tool_use blocks.
                let toolUses = message.contentBlocks?.filter { $0.type == "tool_use" } ?? []
                guard !toolUses.isEmpty else { return .idle }

                // If the session is in bypass mode, tools execute without asking.
                // Check: 1) file-level permission-mode entry, 2) inline permissionMode on entries
                let entryMode = entries.last(where: { $0.permissionMode != nil })?.permissionMode
                let currentMode = entryMode ?? sessionPermissionMode
                let bypassMode = (currentMode == "bypassPermissions" || currentMode == "acceptEdits")

                let needsApproval = !bypassMode && toolUses.contains { block in
                    guard let name = block.toolName else { return false }
                    return !permissionChecker.isAutoApproved(tool: name, input: block.toolInput)
                }

                if needsApproval {
                    return .waitingForUser
                }

                // All pending tools auto-approved — actively executing
                let toolName = toolUses.last?.toolName ?? "unknown"
                return .executingTool(toolName)

            case "end_turn":
                // Text question heuristic: if last text contains ? and age > 3s,
                // treat as waiting for user. stop_reason=end_turn already confirms
                // streaming is done, so we only need a brief settling delay.
                let age = now.timeIntervalSince(lastEntry.timestamp)
                if age > 3, Self.isTextAskingQuestion(message) {
                    return .waitingForUser
                }
                return .idle

            case nil:
                // Still generating (no stop_reason yet means streaming).
                // Process is alive → trust it's still streaming.
                return .thinking

            default:
                return .idle
            }

        default:
            return .idle
        }
    }

    // MARK: - Path Encoding

    /// Encode a project path the same way Claude Code does for directory names:
    /// every non-alphanumeric character is replaced by "-".
    static func encodeProjectPath(_ path: String) -> String {
        var result = ""
        for c in path.unicodeScalars {
            if CharacterSet.alphanumerics.contains(c) {
                result.append(Character(c))
            } else {
                result.append("-")
            }
        }
        return result
    }

    // MARK: - Running Session Discovery (process-centric, à la c9watch)

    /// Discover session IDs that have a live Claude process.
    /// Two-step approach:
    /// 1. Primary: Read ~/.claude/sessions/{pid}.json for all live PIDs
    /// 2. Fallback: Scan process table for "claude" processes, match CWD to project dirs
    /// Maps sessionId → PID for terminal detection
    private var sessionPidMap: [String: pid_t] = [:]

    private func discoverRunningSessions(fm: FileManager) -> Set<String> {
        var sessionIds = Set<String>()
        sessionPidMap.removeAll()

        // Primary: PID files → authoritative session mapping
        let sessionsDir = configDir + "/sessions"
        if let files = try? fm.contentsOfDirectory(atPath: sessionsDir) {
            for file in files {
                guard file.hasSuffix(".json"),
                      let pid = pid_t(file.dropLast(5)) else { continue }

                let alive = kill(pid, 0)
                let err = errno
                guard alive == 0 || err == EPERM else {
                    log.debug("PID \(pid) not alive (errno=\(err))")
                    continue
                }

                let filePath = sessionsDir + "/" + file
                guard let data = fm.contents(atPath: filePath),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sessionId = json["sessionId"] as? String else {
                    log.warning("Could not read sessionId from \(file)")
                    continue
                }

                log.debug("PID \(pid) alive → session \(sessionId)")
                sessionIds.insert(sessionId)
                sessionPidMap[sessionId] = pid
            }
        }

        // Fallback: scan process table for Claude processes without PID files.
        // Uses /bin/ps to find processes whose command contains "claude".
        if sessionIds.isEmpty {
            sessionIds = discoverViaProcessTable(fm: fm)
        }

        return sessionIds
    }

    /// Scan the process table for Claude Code processes.
    /// Matches processes whose command contains "claude" (handles node-based installs).
    /// Maps each process CWD → encoded project dir → most recently modified JSONL.
    private func discoverViaProcessTable(fm: FileManager) -> Set<String> {
        // Get Claude-related PIDs from the process table
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid,comm"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var claudePids: [pid_t] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().contains("claude") else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            if let pidStr = parts.first, let pid = pid_t(pidStr) {
                claudePids.append(pid)
            }
        }

        guard !claudePids.isEmpty else { return [] }

        // For each Claude PID, try to get its CWD and match to a project JSONL
        var sessionIds = Set<String>()
        let projectsDir = configDir + "/projects"

        for pid in claudePids {
            // Try reading CWD via /proc or lsof (macOS doesn't have /proc)
            let cwdPipe = Pipe()
            let lsof = Process()
            lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsof.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
            lsof.standardOutput = cwdPipe
            lsof.standardError = FileHandle.nullDevice
            do { try lsof.run() } catch { continue }
            let lsofData = cwdPipe.fileHandleForReading.readDataToEndOfFile()
            lsof.waitUntilExit()
            guard let lsofOutput = String(data: lsofData, encoding: .utf8) else { continue }

            // lsof -Fn outputs "n<path>" lines
            var cwd: String?
            for line in lsofOutput.components(separatedBy: "\n") {
                if line.hasPrefix("n/") {
                    cwd = String(line.dropFirst(1))
                    break
                }
            }

            guard let cwd else { continue }

            // Encode CWD and find matching project directory
            let encoded = ClaudeProvider.encodeProjectPath(cwd)
            let projectPath = projectsDir + "/" + encoded
            guard fm.fileExists(atPath: projectPath) else { continue }

            // Find the most recently modified JSONL in this project
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }
            var bestFile: (String, Date)?
            for file in files {
                guard file.hasSuffix(".jsonl"), !file.hasPrefix("agent-") else { continue }
                let fullPath = projectPath + "/" + file
                if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let mtime = attrs[.modificationDate] as? Date {
                    if bestFile == nil || mtime > bestFile!.1 {
                        bestFile = (file, mtime)
                    }
                }
            }

            if let (file, _) = bestFile {
                sessionIds.insert(String(file.dropLast(6)))
            }
        }

        return sessionIds
    }

    // MARK: - File Reading

    /// Read the last ~`count` entries from a JSONL file.
    /// For large files (>10KB), seeks near the end to avoid reading the whole file.
    private func readRecentEntries(from path: String, count: Int, fm: FileManager) -> [ClaudeJSONLEntry] {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return []
        }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        guard fileSize > 0 else { return [] }

        let text: String

        if fileSize > 10240 {
            // Large file: seek near the end
            let bytesToRead = UInt64(count) * 4096
            let seekPos = fileSize > bytesToRead ? fileSize - bytesToRead : 0
            handle.seek(toFileOffset: seekPos)
            let data = handle.readDataToEndOfFile()
            guard let str = String(data: data, encoding: .utf8) else {
                return []
            }
            // If we seeked into the middle of a line, skip the first partial line
            if seekPos > 0, let firstNewline = str.firstIndex(of: "\n") {
                text = String(str[str.index(after: firstNewline)...])
            } else {
                text = str
            }
        } else {
            handle.seek(toFileOffset: 0)
            let data = handle.readDataToEndOfFile()
            guard let str = String(data: data, encoding: .utf8) else {
                return []
            }
            text = str
        }

        let lines = text.components(separatedBy: "\n")
        var entries: [ClaudeJSONLEntry] = []

        // Parse from the end, collecting up to `count` meaningful entries
        for line in lines.reversed() {
            guard entries.count < count else { break }
            if let entry = ClaudeJSONLEntry.parse(line) {
                entries.append(entry)
            }
        }

        // Reverse to get chronological order
        return entries.reversed()
    }
}
