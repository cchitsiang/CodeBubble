import Foundation
import SQLite3

/// Monitors OpenCode sessions via SQLite + process detection.
/// Shows sessions for running `opencode` processes, matching by CWD to threads in opencode.db.
final class OpenCodeProvider: SessionProvider {
    let source = "opencode"

    private let dbPath: String

    init(dbPath: String? = nil) {
        if let path = dbPath {
            self.dbPath = path
        } else if let dataDir = ProcessInfo.processInfo.environment["OPENCODE_DATA_DIR"] {
            self.dbPath = dataDir + "/opencode.db"
        } else {
            self.dbPath = NSHomeDirectory() + "/.local/share/opencode/opencode.db"
        }
    }

    func discoverSessions() -> [AgentSession] {
        // Step 1: Find running opencode processes
        let openCodeProcesses = findOpenCodeProcesses()
        guard !openCodeProcesses.isEmpty else { return [] }

        // Step 2: Read sessions from SQLite (if DB exists)
        let sessions = readSessionsFromDB()

        // Step 3: Match processes to sessions, or create idle sessions for unmatched processes
        var results: [AgentSession] = []
        var matchedProcesses = Set<pid_t>()

        for sess in sessions {
            // Match by CWD
            if let proc = openCodeProcesses.first(where: { $0.cwd == sess.cwd }) {
                matchedProcesses.insert(proc.pid)
            } else {
                continue
            }

            results.append(AgentSession(
                id: sess.id,
                source: source,
                cwd: sess.cwd,
                model: sess.model,
                gitBranch: sess.cwd.flatMap { gitBranchForPath($0) },
                activity: sess.activity,
                lastActivity: sess.timeUpdated,
                lastUserPrompt: sess.lastUserPrompt,
                lastAssistantMessage: sess.lastAssistantMessage,
                currentTool: sess.currentTool,
                toolDescription: sess.title
            ))
        }

        // Step 4: Create idle sessions for running processes without a DB session
        for proc in openCodeProcesses where !matchedProcesses.contains(proc.pid) {
            let projectName = (proc.cwd as NSString).lastPathComponent
            results.append(AgentSession(
                id: "opencode-\(proc.pid)",
                source: source,
                cwd: proc.cwd,
                model: nil,
                gitBranch: gitBranchForPath(proc.cwd),
                activity: .idle,
                lastActivity: Date(),
                lastUserPrompt: nil,
                lastAssistantMessage: nil,
                currentTool: nil,
                toolDescription: projectName
            ))
        }

        return results
    }

    // MARK: - Process Detection

    private struct OpenCodeProcess {
        let pid: pid_t
        let cwd: String
    }

    private func findOpenCodeProcesses() -> [OpenCodeProcess] {
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

        var results: [OpenCodeProcess] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match `opencode` binary but exclude node-based wrappers that contain "opencode" in paths
            guard trimmed.hasSuffix("/opencode") || trimmed.hasSuffix(" opencode") else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard let pidStr = parts.first, let pid = pid_t(pidStr) else { continue }

            guard let cwd = getCwd(pid: pid) else { continue }
            results.append(OpenCodeProcess(pid: pid, cwd: cwd))
        }

        return results
    }

    private func getCwd(pid: pid_t) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("n/") {
                return String(line.dropFirst(1))
            }
        }
        return nil
    }

    // MARK: - SQLite Session Reading

    private struct OpenCodeSession {
        let id: String
        let cwd: String?
        let title: String?
        let model: String?
        let timeUpdated: Date
        let activity: SessionActivity
        let lastUserPrompt: String?
        let lastAssistantMessage: String?
        let currentTool: String?
    }

    private func readSessionsFromDB() -> [OpenCodeSession] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = db else {
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, directory, title, time_updated
        FROM session
        WHERE (parent_id IS NULL OR parent_id = '') AND time_archived IS NULL
        ORDER BY time_updated DESC
        LIMIT 20
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var sessions: [OpenCodeSession] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idCStr = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idCStr)
            let cwd = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let title = sqlite3_column_text(stmt, 2).map { String(cString: $0) }

            // time_updated is stored in milliseconds
            let timeMs = sqlite3_column_int64(stmt, 3)
            let timeUpdated = Date(timeIntervalSince1970: Double(timeMs) / 1000.0)

            let (activity, prompt, msg, tool, model) = readSessionActivity(db: db, sessionId: id)

            sessions.append(OpenCodeSession(
                id: id,
                cwd: cwd,
                title: title,
                model: model,
                timeUpdated: timeUpdated,
                activity: activity,
                lastUserPrompt: prompt,
                lastAssistantMessage: msg,
                currentTool: tool
            ))
        }

        return sessions
    }

    private func readSessionActivity(
        db: OpaquePointer,
        sessionId: String
    ) -> (activity: SessionActivity, prompt: String?, msg: String?, tool: String?, model: String?) {
        let sql = """
        SELECT m.data, p.data FROM message m
        LEFT JOIN part p ON p.message_id = m.id
        WHERE m.session_id = ?
        ORDER BY m.time_created DESC, p.time_created DESC
        LIMIT 5
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return (.idle, nil, nil, nil, nil)
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

        struct Row {
            let message: [String: Any]
            let part: [String: Any]?
        }
        var rows: [Row] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let mPtr = sqlite3_column_text(stmt, 0),
                  let mData = String(cString: mPtr).data(using: .utf8),
                  let mJson = try? JSONSerialization.jsonObject(with: mData) as? [String: Any] else { continue }

            var part: [String: Any]?
            if let pPtr = sqlite3_column_text(stmt, 1),
               let pData = String(cString: pPtr).data(using: .utf8),
               let pJson = try? JSONSerialization.jsonObject(with: pData) as? [String: Any] {
                part = pJson
            }
            rows.append(Row(message: mJson, part: part))
        }

        guard !rows.isEmpty else { return (.idle, nil, nil, nil, nil) }

        let first = rows[0].message
        let role = first["role"] as? String ?? ""
        let finish = first["finish"] as? String ?? ""
        let model = first["modelID"] as? String
        let firstMsgParts = rows.compactMap { $0.part }
        let hasToolPart = firstMsgParts.contains { ($0["type"] as? String) == "tool" }

        // Determine last activity time from message's time.completed or time.created
        let msgTime = first["time"] as? [String: Any]
        let tsMs = (msgTime?["completed"] as? Double) ?? (msgTime?["created"] as? Double) ?? 0
        let lastTime = Date(timeIntervalSince1970: tsMs / 1000.0)
        let age = Date().timeIntervalSince(lastTime)

        let activity: SessionActivity
        switch role {
        case "assistant" where (finish == "tool-calls" || hasToolPart) && !(finish == "stop" || finish == "end_turn"):
            // Actively executing a tool
            if age < 60 {
                let toolName = firstMsgParts
                    .first(where: { ($0["type"] as? String) == "tool" })
                    .flatMap { $0["tool"] as? String } ?? "Tool"
                activity = .executingTool(toolName)
            } else {
                activity = .idle
            }
        case "assistant":
            // Assistant finished responding — session is idle waiting for next input
            activity = .idle
        case "user":
            // User just sent a message, AI is generating
            activity = age < 30 ? .thinking : .idle
        default:
            activity = .idle
        }

        let prompt = rows.first(where: { ($0.message["role"] as? String) == "user" })
            .flatMap { row -> String? in
                if let p = row.part, (p["type"] as? String) == "text" { return p["text"] as? String }
                return nil
            }
        let msg = rows.first(where: { ($0.message["role"] as? String) == "assistant" })
            .flatMap { row -> String? in
                if let p = row.part, (p["type"] as? String) == "text" { return p["text"] as? String }
                return nil
            }

        var tool: String?
        if case .executingTool(let name) = activity { tool = name }

        return (activity, prompt, msg, tool, model)
    }

    // MARK: - Git Branch

    private func gitBranchForPath(_ path: String) -> String? {
        let headPath = path + "/.git/HEAD"
        guard let content = try? String(contentsOfFile: headPath, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        return nil
    }
}
