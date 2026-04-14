import Foundation

/// Reads Claude Code's permission settings and determines if a tool call is auto-approved.
/// Ported from c9watch's permission checker logic.
struct ClaudePermissionChecker {
    /// Tools that are always auto-approved (read-only or safe operations).
    /// Note: AskUserQuestion is intentionally NOT here — it blocks waiting for
    /// user input, so JSONL detection should classify it as .waitingForUser.
    private static let alwaysAllowedTools: Set<String> = [
        "Read", "Glob", "Grep", "WebFetch", "WebSearch",
        "Task", "TaskList", "TaskGet", "TaskCreate", "TaskUpdate",
    ]

    enum Pattern {
        case bashPrefix(String, wildcard: Bool)
        case toolName(String)
        case mcp(String)
        case skill(String)
    }

    let patterns: [Pattern]

    /// Load permissions from ~/.claude/settings.json (and optionally .claude/settings.local.json).
    static func load(from configDir: String) -> ClaudePermissionChecker {
        var allow: [String] = []

        for path in [configDir + "/settings.json"] {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let permissions = json["permissions"] as? [String: Any],
                  let list = permissions["allow"] as? [String] else { continue }
            allow.append(contentsOf: list)
        }

        return ClaudePermissionChecker(patterns: allow.compactMap(Self.parse))
    }

    /// Parse an allow-list entry into a Pattern.
    static func parse(_ raw: String) -> Pattern? {
        if raw.hasPrefix("Bash(") && raw.hasSuffix(")") {
            let inner = String(raw.dropFirst(5).dropLast())
            if let prefix = inner.split(separator: ":", maxSplits: 1).first, inner.hasSuffix(":*") {
                return .bashPrefix(String(prefix), wildcard: true)
            }
            return .bashPrefix(inner, wildcard: false)
        }
        if raw.hasPrefix("mcp__") {
            return .mcp(raw)
        }
        if raw.hasPrefix("Skill(") && raw.hasSuffix(")") {
            return .skill(String(raw.dropFirst(6).dropLast()))
        }
        if !raw.contains("(") && !raw.contains("__") {
            return .toolName(raw)
        }
        return nil
    }

    /// Check if a tool use is auto-approved — safe to run without user approval.
    func isAutoApproved(tool: String, input: [String: Any]?) -> Bool {
        // Always-allowed tools (read-only / safe)
        if Self.alwaysAllowedTools.contains(tool) { return true }

        // Bash: match command against allow-list patterns
        if tool == "Bash" {
            let command = (input?["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            for pattern in patterns {
                if case .bashPrefix(let prefix, let wildcard) = pattern {
                    if wildcard {
                        if command.hasPrefix(prefix) { return true }
                    } else {
                        if command == prefix { return true }
                    }
                }
            }
            return false
        }

        // Write / Edit / NotebookEdit: require explicit allow
        if tool == "Write" || tool == "Edit" || tool == "NotebookEdit" {
            return patterns.contains { if case .toolName(let n) = $0, n == tool { return true } else { return false } }
        }

        // MCP tools: check pattern
        if tool.hasPrefix("mcp__") {
            return patterns.contains { if case .mcp(let n) = $0, n == tool { return true } else { return false } }
        }

        // Default: needs permission
        return false
    }
}
