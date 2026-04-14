import Foundation

public struct SessionSnapshot {
    public var status: AgentStatus = .idle
    public var currentTool: String?
    public var toolDescription: String?
    public var lastActivity: Date = Date()
    public var cwd: String?
    public var model: String?
    public var gitBranch: String?
    public var startTime: Date = Date()
    public var lastUserPrompt: String?
    public var lastAssistantMessage: String?
    public var source: String = "claude"
    public var terminalBundleId: String?
    /// Tool name awaiting approval (only set when status == .waitingForUser)
    public var pendingApprovalTool: String?
    /// Short description of the pending tool invocation
    public var pendingApprovalDetail: String?

    public init(startTime: Date = Date()) {
        self.startTime = startTime
    }

    public var projectDisplayName: String? {
        guard let cwd else { return nil }
        return (cwd as NSString).lastPathComponent
    }
}

// MARK: - SessionSummary

public struct SessionSummary {
    public let status: AgentStatus
    public let primarySource: String
    public let activeSessionCount: Int
    public let totalSessionCount: Int

    public init(status: AgentStatus, primarySource: String, activeSessionCount: Int, totalSessionCount: Int) {
        self.status = status
        self.primarySource = primarySource
        self.activeSessionCount = activeSessionCount
        self.totalSessionCount = totalSessionCount
    }
}

public func deriveSessionSummary(from sessions: [String: SessionSnapshot]) -> SessionSummary {
    var highestStatus: AgentStatus = .idle
    var source = "claude"
    var active = 0
    var mostRecentIdleSource: (source: String, time: Date)?

    for session in sessions.values {
        if session.status != .idle {
            active += 1
        } else if mostRecentIdleSource == nil || session.lastActivity > mostRecentIdleSource!.time {
            mostRecentIdleSource = (session.source, session.lastActivity)
        }

        switch session.status {
        case .waitingForUser:
            if highestStatus != .waitingForUser {
                highestStatus = .waitingForUser
                source = session.source
            }
        case .running:
            if highestStatus == .idle || highestStatus == .thinking {
                highestStatus = .running
                source = session.source
            }
        case .thinking:
            if highestStatus == .idle {
                highestStatus = .thinking
                source = session.source
            }
        case .idle:
            break
        }
    }

    if highestStatus == .idle, let idleSource = mostRecentIdleSource?.source {
        source = idleSource
    }

    return SessionSummary(
        status: highestStatus,
        primarySource: source,
        activeSessionCount: active,
        totalSessionCount: sessions.count
    )
}
