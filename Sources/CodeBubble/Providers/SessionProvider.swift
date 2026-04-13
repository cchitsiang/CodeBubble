import Foundation

// MARK: - SessionActivity

/// Represents the current status of an agent session.
enum SessionActivity: Equatable {
    /// The AI is generating a response (last entry is a user message).
    case thinking

    /// The agent is running a named tool.
    case executingTool(String)

    /// The agent is waiting for user input (stop_reason == end_turn).
    case waitingForUser

    /// No recent activity.
    case idle
}

// MARK: - AgentSession

/// A discovered session from any provider.
struct AgentSession {
    /// Unique session identifier.
    let id: String

    /// Provider source identifier (e.g. "claude", "codex", "opencode").
    let source: String

    /// Working directory of the session, if known.
    let cwd: String?

    /// Model name used by the session, if known.
    let model: String?

    /// Current git branch of the working directory, if known.
    let gitBranch: String?

    /// Current activity status of the session.
    let activity: SessionActivity

    /// Timestamp of the most recent activity.
    let lastActivity: Date

    /// The most recent user prompt, if available.
    let lastUserPrompt: String?

    /// The most recent assistant message, if available.
    let lastAssistantMessage: String?

    /// Name of the tool currently being executed, if any.
    let currentTool: String?

    /// Human-readable description of the current tool invocation, if any.
    let toolDescription: String?

    /// Name of the tool awaiting approval (e.g. "Bash"), if activity == .waitingForUser for a permission request.
    var pendingApprovalTool: String? = nil

    /// Short description of the pending tool invocation (e.g. the Bash command), if any.
    var pendingApprovalDetail: String? = nil
}

// MARK: - SessionProvider

/// A type that can discover active agent sessions from a specific source.
protocol SessionProvider {
    /// Unique identifier for this provider (e.g. "claude", "codex", "opencode").
    var source: String { get }

    /// Discover and return all currently active sessions from this provider.
    func discoverSessions() -> [AgentSession]
}
