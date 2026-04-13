import Foundation
import CodeBubbleCore

struct PersistedSession: Codable {
    let sessionId: String
    let cwd: String?
    let source: String
    let model: String?
    let lastUserPrompt: String?
    let lastAssistantMessage: String?
    let startTime: Date
    let lastActivity: Date
}

enum SessionPersistence {
    private static let dirPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.codebubble"
    private static let filePath = dirPath + "/sessions.json"

    static func save(_ sessions: [String: SessionSnapshot]) {
        let persisted: [PersistedSession] = sessions.map { (id, s) in
            PersistedSession(
                sessionId: id,
                cwd: s.cwd,
                source: s.source,
                model: s.model,
                lastUserPrompt: s.lastUserPrompt,
                lastAssistantMessage: s.lastAssistantMessage,
                startTime: s.startTime,
                lastActivity: s.lastActivity
            )
        }
        do {
            try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persisted)
            try data.write(to: URL(fileURLWithPath: filePath), options: Data.WritingOptions.atomic)
        } catch {}
    }

    static func load() -> [PersistedSession] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PersistedSession].self, from: data)) ?? []
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: filePath)
    }
}
