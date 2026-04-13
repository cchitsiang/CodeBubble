import Foundation

public enum AgentStatus: Equatable {
    case idle
    case thinking
    case running
    case waitingForUser
}

public struct ToolHistoryEntry: Identifiable {
    public let id = UUID()
    public let tool: String
    public let description: String?
    public let timestamp: Date

    public init(tool: String, description: String?, timestamp: Date) {
        self.tool = tool
        self.description = description
        self.timestamp = timestamp
    }
}

public struct ChatMessage: Identifiable {
    public let id = UUID()
    public let isUser: Bool
    public let text: String

    public init(isUser: Bool, text: String) {
        self.isUser = isUser
        self.text = text
    }
}
