import XCTest
@testable import CodeBubble

final class SessionPersistenceTests: XCTestCase {
    func testPersistedSessionDecodesBasicFields() throws {
        let json = """
        {
          "sessionId": "session-1",
          "cwd": "/tmp/demo",
          "source": "claude",
          "model": "claude-sonnet-4",
          "lastUserPrompt": "hi",
          "lastAssistantMessage": "hello",
          "startTime": "2026-04-09T10:00:00Z",
          "lastActivity": "2026-04-09T10:01:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(PersistedSession.self, from: Data(json.utf8))

        XCTAssertEqual(session.sessionId, "session-1")
        XCTAssertEqual(session.source, "claude")
        XCTAssertEqual(session.cwd, "/tmp/demo")
        XCTAssertEqual(session.lastUserPrompt, "hi")
    }

    func testPersistedSessionRoundTrip() throws {
        let startTime = ISO8601DateFormatter().date(from: "2026-04-09T10:00:00Z")!
        let session = PersistedSession(
            sessionId: "session-2",
            cwd: "/tmp/demo",
            source: "codex",
            model: "gpt-5",
            lastUserPrompt: "ping",
            lastAssistantMessage: "pong",
            startTime: startTime,
            lastActivity: startTime.addingTimeInterval(30)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(session)
        let decoded = try decoder.decode(PersistedSession.self, from: data)

        XCTAssertEqual(decoded.sessionId, "session-2")
        XCTAssertEqual(decoded.source, "codex")
        XCTAssertEqual(decoded.model, "gpt-5")
    }
}
