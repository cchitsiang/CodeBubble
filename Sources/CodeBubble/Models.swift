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
