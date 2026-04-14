import Foundation
import CodeBubbleCore

/// Represents a single pending permission approval received via hook.
/// The continuation resumes with the JSON response to send back to Claude Code.
struct HookApproval: Identifiable {
    let id = UUID()
    let sessionId: String
    let toolName: String
    let toolInput: [String: Any]
    let continuation: CheckedContinuation<Data, Never>
}

/// A single question item from AskUserQuestion.
struct QuestionItem {
    let question: String
    let header: String?
    let options: [String]?
    let descriptions: [String]?
    let answerKey: String
}

/// A question batch from the AskUserQuestion tool, received via hook.
struct HookQuestion: Identifiable {
    let id = UUID()
    let sessionId: String
    let items: [QuestionItem]
    let continuation: CheckedContinuation<Data, Never>
}
