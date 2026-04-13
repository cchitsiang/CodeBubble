import Foundation
import SQLite3
import os.log

private let log = Logger(subsystem: "com.codebubble", category: "CodexProvider")

/// Monitors Codex CLI sessions via SQLite (state_5.sqlite) + process detection.
/// Newer Codex versions store threads in SQLite, older ones used JSONL.
final class CodexProvider: SessionProvider {
    let source = "codex"

    private let codexDir: String
    private let dbPath: String

    init(codexDir: String? = nil) {
        let dir = codexDir ?? (NSHomeDirectory() + "/.codex")
        self.codexDir = dir
        self.dbPath = dir + "/state_5.sqlite"
    }

    func discoverSessions() -> [AgentSession] {
        // Step 1: Find running codex processes
        let codexProcesses = findCodexProcesses()
        guard !codexProcesses.isEmpty else { return [] }

        // Step 2: Read threads from SQLite (if available)
        let threads = readThreadsFromDB()

        // Step 3: Match processes to threads, or create idle sessions for unmatched processes
        var results: [AgentSession] = []
        var matchedProcesses = Set<pid_t>()

        for thread in threads {
            // Try to match thread CWD to a running process CWD
            if let proc = codexProcesses.first(where: { $0.cwd == thread.cwd }) {
                matchedProcesses.insert(proc.pid)
            } else {
                // Thread exists but no matching process — skip
                continue
            }

            results.append(AgentSession(
                id: thread.id,
                source: source,
                cwd: thread.cwd,
                model: thread.model,
                gitBranch: thread.gitBranch,
                activity: thread.activity,
                lastActivity: thread.updatedAt,
                lastUserPrompt: thread.firstUserMessage,
                lastAssistantMessage: nil,
                currentTool: nil,
                toolDescription: thread.title
            ))
        }

        // Step 4: Create idle sessions for running processes without threads
        for proc in codexProcesses where !matchedProcesses.contains(proc.pid) {
            let projectName = (proc.cwd as NSString).lastPathComponent
            results.append(AgentSession(
                id: "codex-\(proc.pid)",
                source: source,
                cwd: proc.cwd,
                model: nil,
                gitBranch: nil,
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

    private struct CodexProcess {
        let pid: pid_t
        let cwd: String
    }

    private func findCodexProcesses() -> [CodexProcess] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid,comm"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }

        // Read pipe BEFORE waitUntilExit to avoid deadlock if buffer fills
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var results: [CodexProcess] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().contains("codex") else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard let pidStr = parts.first, let pid = pid_t(pidStr) else { continue }

            // Get CWD via lsof
            guard let cwd = getCwd(pid: pid) else { continue }
            results.append(CodexProcess(pid: pid, cwd: cwd))
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

    // MARK: - SQLite Thread Reading

    private struct CodexThread {
        let id: String
        let cwd: String
        let title: String?
        let model: String?
        let gitBranch: String?
        let firstUserMessage: String?
        let updatedAt: Date
        let activity: SessionActivity
    }

    private func readThreadsFromDB() -> [CodexThread] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, cwd, title, model, git_branch, first_user_message, updated_at, approval_mode
        FROM threads
        WHERE archived = 0
        ORDER BY updated_at DESC
        LIMIT 20
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var threads: [CodexThread] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let cwd = String(cString: sqlite3_column_text(stmt, 1))
            let title = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let model = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let gitBranch = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let firstUserMessage = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))

            // If the thread hasn't been updated in > 5 min, it's idle
            let age = Date().timeIntervalSince(updatedAt)
            let activity: SessionActivity = age < 30 ? .thinking : .idle

            threads.append(CodexThread(
                id: id,
                cwd: cwd,
                title: title,
                model: model,
                gitBranch: gitBranch,
                firstUserMessage: firstUserMessage,
                updatedAt: updatedAt,
                activity: activity
            ))
        }

        return threads
    }
}
