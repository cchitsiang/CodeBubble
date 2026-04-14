import XCTest
@testable import CodeBubble

final class ClaudeProviderTests: XCTestCase {

    // MARK: - Helpers

    private func makeTimestamp(_ offset: TimeInterval = 0) -> Date {
        Date().addingTimeInterval(offset)
    }

    private func isoString(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    // MARK: - 1. Parsing a user JSONL entry

    func testParseUserEntry() throws {
        let ts = "2026-04-10T12:34:56.789Z"
        let line = """
        {"type":"user","sessionId":"abc-123","timestamp":"\(ts)","cwd":"/tmp/project","gitBranch":"main","version":"1.2.3","message":{"role":"user","content":"Hello world"}}
        """

        let entry = try XCTUnwrap(ClaudeJSONLEntry.parse(line))

        XCTAssertEqual(entry.type, "user")
        XCTAssertEqual(entry.sessionId, "abc-123")
        XCTAssertEqual(entry.cwd, "/tmp/project")
        XCTAssertEqual(entry.gitBranch, "main")
        XCTAssertEqual(entry.version, "1.2.3")
        XCTAssertNotNil(entry.message)
        XCTAssertEqual(entry.message?.role, "user")

        // Content should be parsed as a single text block
        let blocks = try XCTUnwrap(entry.message?.contentBlocks)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, "text")
        XCTAssertEqual(blocks[0].text, "Hello world")

        // Verify timestamp
        let expectedDate = ClaudeJSONLEntry.parseTimestamp(ts)
        XCTAssertEqual(entry.timestamp, expectedDate)
    }

    func testParseUserEntryWithArrayContent() throws {
        let ts = "2026-04-10T12:34:56.789Z"
        let line = """
        {"type":"user","sessionId":"abc-123","timestamp":"\(ts)","message":{"role":"user","content":[{"type":"text","text":"Hello"},{"type":"text","text":"World"}]}}
        """

        let entry = try XCTUnwrap(ClaudeJSONLEntry.parse(line))
        let blocks = try XCTUnwrap(entry.message?.contentBlocks)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].text, "Hello")
        XCTAssertEqual(blocks[1].text, "World")
    }

    // MARK: - 2. Parsing an assistant entry with tool_use

    func testParseAssistantEntryWithToolUse() throws {
        let ts = "2026-04-10T12:35:00.000Z"
        let line = """
        {"type":"assistant","sessionId":"abc-123","timestamp":"\(ts)","message":{"role":"assistant","model":"claude-sonnet-4-20250514","content":[{"type":"text","text":"Let me check that file."},{"type":"tool_use","name":"Read","id":"tool-1"}],"stop_reason":"tool_use"}}
        """

        let entry = try XCTUnwrap(ClaudeJSONLEntry.parse(line))

        XCTAssertEqual(entry.type, "assistant")
        XCTAssertEqual(entry.sessionId, "abc-123")
        XCTAssertNotNil(entry.message)
        XCTAssertEqual(entry.message?.role, "assistant")
        XCTAssertEqual(entry.message?.model, "claude-sonnet-4-20250514")
        XCTAssertEqual(entry.message?.stopReason, "tool_use")

        let blocks = try XCTUnwrap(entry.message?.contentBlocks)
        XCTAssertEqual(blocks.count, 2)

        // First block: text
        XCTAssertEqual(blocks[0].type, "text")
        XCTAssertEqual(blocks[0].text, "Let me check that file.")

        // Second block: tool_use
        XCTAssertEqual(blocks[1].type, "tool_use")
        XCTAssertEqual(blocks[1].toolName, "Read")
        XCTAssertEqual(blocks[1].toolId, "tool-1")
    }

    func testParseAssistantEntryWithToolResult() throws {
        let ts = "2026-04-10T12:35:01.000Z"
        let line = """
        {"type":"assistant","sessionId":"abc-123","timestamp":"\(ts)","message":{"role":"assistant","content":[{"type":"tool_result","tool_use_id":"tool-1","text":"file contents here"}],"stop_reason":"end_turn"}}
        """

        let entry = try XCTUnwrap(ClaudeJSONLEntry.parse(line))
        let blocks = try XCTUnwrap(entry.message?.contentBlocks)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, "tool_result")
        XCTAssertEqual(blocks[0].toolId, "tool-1")
    }

    // MARK: - 3. Status: thinking (last entry = user)

    func testDetermineActivityThinking() {
        let now = Date()
        let entries = [
            ClaudeJSONLEntry(
                type: "user",
                sessionId: "s1",
                timestamp: now.addingTimeInterval(-5), // 5 seconds ago
                cwd: "/tmp",
                gitBranch: nil,
                version: nil, permissionMode: nil,
                message: ClaudeMessage(role: "user", model: nil, contentBlocks: nil, stopReason: nil)
            )
        ]

        let activity = ClaudeProvider.determineActivity(from: entries, now: now)
        XCTAssertEqual(activity, .thinking)
    }

    func testDetermineActivityUserMessageStaysThinkingRegardlessOfAge() {
        // With process-centric detection, a pending user message means Claude is
        // still working on it — don't time out.
        let now = Date()
        let entries = [
            ClaudeJSONLEntry(
                type: "user",
                sessionId: "s1",
                timestamp: now.addingTimeInterval(-600), // 10 min ago
                cwd: nil,
                gitBranch: nil,
                version: nil, permissionMode: nil,
                message: ClaudeMessage(role: "user", model: nil, contentBlocks: nil, stopReason: nil)
            )
        ]

        let activity = ClaudeProvider.determineActivity(from: entries, now: now)
        XCTAssertEqual(activity, .thinking)
    }

    // MARK: - 4. Status: executingTool (assistant with stop_reason=tool_use)

    func testDetermineActivityExecutingToolJustStarted() {
        // Within 3 seconds of tool_use — treat as actively executing
        let now = Date()
        let entries = [
            ClaudeJSONLEntry(
                type: "assistant",
                sessionId: "s1",
                timestamp: now.addingTimeInterval(-1),
                cwd: nil,
                gitBranch: nil,
                version: nil, permissionMode: nil,
                message: ClaudeMessage(
                    role: "assistant",
                    model: "claude-sonnet-4-20250514",
                    contentBlocks: [
                        ClaudeContentBlock(type: "text", text: "Let me read it.", toolName: nil, toolId: nil, toolInput: nil),
                        ClaudeContentBlock(type: "tool_use", text: nil, toolName: "Read", toolId: "t1", toolInput: nil)
                    ],
                    stopReason: "tool_use"
                )
            )
        ]

        let activity = ClaudeProvider.determineActivity(from: entries, now: now)
        XCTAssertEqual(activity, .executingTool("Read"))
    }

    func testDetermineActivityToolUsePendingTreatedAsWaiting() {
        // Tool_use pending for > 3s usually means waiting for user approval
        let now = Date()
        let entries = [
            ClaudeJSONLEntry(
                type: "assistant",
                sessionId: "s1",
                timestamp: now.addingTimeInterval(-10),
                cwd: nil,
                gitBranch: nil,
                version: nil, permissionMode: nil,
                message: ClaudeMessage(
                    role: "assistant",
                    model: nil,
                    contentBlocks: [
                        ClaudeContentBlock(type: "tool_use", text: nil, toolName: "Bash", toolId: "t1", toolInput: nil)
                    ],
                    stopReason: "tool_use"
                )
            )
        ]

        let activity = ClaudeProvider.determineActivity(from: entries, now: now)
        XCTAssertEqual(activity, .waitingForUser)
    }

    func testDetermineActivityOldToolUseStillWaitingIfProcessAlive() {
        // With process-centric detection, sessions only exist while process is alive.
        // Old tool_use (no matching result) = still pending approval, regardless of age.
        let now = Date()
        let entries = [
            ClaudeJSONLEntry(
                type: "assistant",
                sessionId: "s1",
                timestamp: now.addingTimeInterval(-3600), // 1 hour ago
                cwd: nil,
                gitBranch: nil,
                version: nil, permissionMode: nil,
                message: ClaudeMessage(
                    role: "assistant",
                    model: nil,
                    contentBlocks: [
                        ClaudeContentBlock(type: "tool_use", text: nil, toolName: "Bash", toolId: "t1", toolInput: nil)
                    ],
                    stopReason: "tool_use"
                )
            )
        ]

        let activity = ClaudeProvider.determineActivity(from: entries, now: now)
        XCTAssertEqual(activity, .waitingForUser)
    }

    // MARK: - Permission-based tool_use classification

    func testDetermineActivityAutoApprovedToolIsWorking() {
        // A Bash command matching an allow-list pattern should be executingTool
        let now = Date()
        let checker = ClaudePermissionChecker(patterns: [
            .bashPrefix("ls", wildcard: true)
        ])
        let entries = [
            ClaudeJSONLEntry(
                type: "assistant", sessionId: "s1",
                timestamp: now.addingTimeInterval(-10),
                cwd: nil, gitBranch: nil, version: nil, permissionMode: nil,
                message: ClaudeMessage(
                    role: "assistant", model: nil,
                    contentBlocks: [
                        ClaudeContentBlock(type: "tool_use", text: nil, toolName: "Bash",
                                           toolId: "t1", toolInput: ["command": "ls -la"])
                    ],
                    stopReason: "tool_use"
                )
            )
        ]
        let activity = ClaudeProvider.determineActivity(from: entries, permissionChecker: checker, now: now)
        XCTAssertEqual(activity, .executingTool("Bash"))
    }

    func testDetermineActivityBypassModeSkipsApproval() {
        // When session is in bypassPermissions mode, Bash with no allow rule
        // should still be .executingTool (not .waitingForUser) — bypass means
        // tools run without asking.
        let now = Date()
        let checker = ClaudePermissionChecker(patterns: [])
        let entries = [
            ClaudeJSONLEntry(
                type: "assistant", sessionId: "s1",
                timestamp: now.addingTimeInterval(-1),
                cwd: nil, gitBranch: nil, version: nil,
                permissionMode: "bypassPermissions",
                message: ClaudeMessage(
                    role: "assistant", model: nil,
                    contentBlocks: [
                        ClaudeContentBlock(type: "tool_use", text: nil, toolName: "Bash",
                                           toolId: "t1", toolInput: ["command": "rm -rf /"])
                    ],
                    stopReason: "tool_use"
                )
            )
        ]
        let activity = ClaudeProvider.determineActivity(from: entries, permissionChecker: checker, now: now)
        XCTAssertEqual(activity, .executingTool("Bash"))
    }

    func testDetermineActivityNonAllowedBashIsWaiting() {
        // A Bash command with no allow rule should be waitingForUser
        let now = Date()
        let checker = ClaudePermissionChecker(patterns: [])
        let entries = [
            ClaudeJSONLEntry(
                type: "assistant", sessionId: "s1",
                timestamp: now.addingTimeInterval(-1),
                cwd: nil, gitBranch: nil, version: nil, permissionMode: nil,
                message: ClaudeMessage(
                    role: "assistant", model: nil,
                    contentBlocks: [
                        ClaudeContentBlock(type: "tool_use", text: nil, toolName: "Bash",
                                           toolId: "t1", toolInput: ["command": "rm -rf /"])
                    ],
                    stopReason: "tool_use"
                )
            )
        ]
        let activity = ClaudeProvider.determineActivity(from: entries, permissionChecker: checker, now: now)
        XCTAssertEqual(activity, .waitingForUser)
    }

    // MARK: - ClaudePermissionChecker parsing

    func testParseBashPatternWildcard() {
        guard case .bashPrefix(let prefix, let wildcard) = ClaudePermissionChecker.parse("Bash(git add:*)")! else {
            return XCTFail("expected bashPrefix")
        }
        XCTAssertEqual(prefix, "git add")
        XCTAssertTrue(wildcard)
    }

    func testParseBashPatternExact() {
        guard case .bashPrefix(let prefix, let wildcard) = ClaudePermissionChecker.parse("Bash(npm ci)")! else {
            return XCTFail("expected bashPrefix")
        }
        XCTAssertEqual(prefix, "npm ci")
        XCTAssertFalse(wildcard)
    }

    func testParseMcpPattern() {
        guard case .mcp(let name) = ClaudePermissionChecker.parse("mcp__atlassian__getJiraIssue")! else {
            return XCTFail("expected mcp")
        }
        XCTAssertEqual(name, "mcp__atlassian__getJiraIssue")
    }

    func testAlwaysAllowedTools() {
        let checker = ClaudePermissionChecker(patterns: [])
        XCTAssertTrue(checker.isAutoApproved(tool: "Read", input: nil))
        XCTAssertTrue(checker.isAutoApproved(tool: "Glob", input: nil))
        XCTAssertTrue(checker.isAutoApproved(tool: "Grep", input: nil))
        XCTAssertFalse(checker.isAutoApproved(tool: "Bash", input: ["command": "ls"]))
    }

    func testBashCommandMatching() {
        let checker = ClaudePermissionChecker(patterns: [
            .bashPrefix("git add", wildcard: true),
            .bashPrefix("npm ci", wildcard: false),
        ])
        XCTAssertTrue(checker.isAutoApproved(tool: "Bash", input: ["command": "git add ."]))
        XCTAssertTrue(checker.isAutoApproved(tool: "Bash", input: ["command": "npm ci"]))
        XCTAssertFalse(checker.isAutoApproved(tool: "Bash", input: ["command": "npm ci --legacy"]))
        XCTAssertFalse(checker.isAutoApproved(tool: "Bash", input: ["command": "rm -rf /"]))
    }

    // MARK: - 5. Status: idle (assistant with stop_reason=end_turn — Claude is done)

    func testDetermineActivityEndTurnIsIdle() {
        let now = Date()
        let entries = [
            ClaudeJSONLEntry(
                type: "assistant",
                sessionId: "s1",
                timestamp: now.addingTimeInterval(-5),
                cwd: nil,
                gitBranch: nil,
                version: nil, permissionMode: nil,
                message: ClaudeMessage(
                    role: "assistant",
                    model: nil,
                    contentBlocks: [
                        ClaudeContentBlock(type: "text", text: "Done!", toolName: nil, toolId: nil, toolInput: nil)
                    ],
                    stopReason: "end_turn"
                )
            )
        ]

        let activity = ClaudeProvider.determineActivity(from: entries, now: now)
        XCTAssertEqual(activity, .idle)
    }

    func testDetermineActivityNilStopReasonRecentIsThinking() {
        let now = Date()
        let entries = [
            ClaudeJSONLEntry(
                type: "assistant",
                sessionId: "s1",
                timestamp: now.addingTimeInterval(-5), // 5 seconds ago
                cwd: nil,
                gitBranch: nil,
                version: nil, permissionMode: nil,
                message: ClaudeMessage(
                    role: "assistant",
                    model: nil,
                    contentBlocks: nil,
                    stopReason: nil
                )
            )
        ]

        let activity = ClaudeProvider.determineActivity(from: entries, now: now)
        XCTAssertEqual(activity, .thinking)
    }

    func testDetermineActivityNilStopReasonStaysThinkingRegardlessOfAge() {
        // Streaming incomplete (no stop_reason) = Claude is still generating;
        // process-centric detection trusts the process, so don't time out.
        let now = Date()
        let entries = [
            ClaudeJSONLEntry(
                type: "assistant",
                sessionId: "s1",
                timestamp: now.addingTimeInterval(-600),
                cwd: nil,
                gitBranch: nil,
                version: nil, permissionMode: nil,
                message: ClaudeMessage(
                    role: "assistant",
                    model: nil,
                    contentBlocks: nil,
                    stopReason: nil
                )
            )
        ]

        let activity = ClaudeProvider.determineActivity(from: entries, now: now)
        XCTAssertEqual(activity, .thinking)
    }

    // MARK: - 6. Path encoding

    func testEncodeProjectPath() {
        // Basic Unix path
        XCTAssertEqual(
            ClaudeProvider.encodeProjectPath("/Users/dev/my-project"),
            "-Users-dev-my-project"
        )

        // Path with spaces
        XCTAssertEqual(
            ClaudeProvider.encodeProjectPath("/Users/dev/My Project"),
            "-Users-dev-My-Project"
        )

        // Path with special characters
        XCTAssertEqual(
            ClaudeProvider.encodeProjectPath("/tmp/test@123"),
            "-tmp-test-123"
        )

        // Alphanumeric only stays unchanged
        XCTAssertEqual(
            ClaudeProvider.encodeProjectPath("abc123"),
            "abc123"
        )
    }

    // MARK: - Parsing edge cases

    func testParseSkipsNonMeaningfulTypes() {
        let line = """
        {"type":"summary","timestamp":"2026-04-10T12:34:56.789Z","data":"some summary"}
        """
        XCTAssertNil(ClaudeJSONLEntry.parse(line))
    }

    func testParseMalformedLine() {
        XCTAssertNil(ClaudeJSONLEntry.parse("not-json"))
        XCTAssertNil(ClaudeJSONLEntry.parse(""))
        XCTAssertNil(ClaudeJSONLEntry.parse("{}"))
    }

    func testDetermineActivityEmptyEntries() {
        let activity = ClaudeProvider.determineActivity(from: [])
        XCTAssertEqual(activity, .idle)
    }

    func testParseTimestampWithAndWithoutFractionalSeconds() {
        // With fractional seconds
        let d1 = ClaudeJSONLEntry.parseTimestamp("2026-04-10T12:34:56.789Z")
        XCTAssertNotNil(d1)

        // Without fractional seconds
        let d2 = ClaudeJSONLEntry.parseTimestamp("2026-04-10T12:34:56Z")
        XCTAssertNotNil(d2)
    }

    // MARK: - Text question heuristic (isTextAskingQuestion)

    func testTextQuestionEndsWithQuestionMark() {
        let msg = ClaudeMessage(
            role: "assistant", model: nil,
            contentBlocks: [
                ClaudeContentBlock(type: "text", text: "What is 2 + 2?", toolName: nil, toolId: nil, toolInput: nil)
            ],
            stopReason: "end_turn"
        )
        XCTAssertTrue(ClaudeProvider.isTextAskingQuestion(msg))
    }

    func testTextQuestionWithOptionsAfter() {
        let text = """
        What's your primary motivation for picking Rust?

        - A) Learn Rust — You're new to it and want a project that teaches you the language
        - B) Performance — You have a problem that needs speed, low-level control, or zero-cost abstractions
        - C) Build something real — You want a useful tool/product and Rust happens to be the right fit
        - D) Fun / exploration — You want something interesting to hack on, no particular goal
        """
        let msg = ClaudeMessage(
            role: "assistant", model: nil,
            contentBlocks: [
                ClaudeContentBlock(type: "text", text: text, toolName: nil, toolId: nil, toolInput: nil)
            ],
            stopReason: "end_turn"
        )
        XCTAssertTrue(ClaudeProvider.isTextAskingQuestion(msg))
    }

    func testTextQuestionWithFollowUpSuggestion() {
        let text = """
        Is there a pain point in your daily workflow that annoys you? Something where you think "I wish
        there was a better tool for this"?

        Or if nothing comes to mind, I can propose ideas based on what's underserved in the dev tooling
        space. Just say "propose ideas" and I'll go that route.
        """
        let msg = ClaudeMessage(
            role: "assistant", model: nil,
            contentBlocks: [
                ClaudeContentBlock(type: "text", text: text, toolName: nil, toolId: nil, toolInput: nil)
            ],
            stopReason: "end_turn"
        )
        XCTAssertTrue(ClaudeProvider.isTextAskingQuestion(msg))
    }

    func testTextNotAQuestionDeclarativeEnding() {
        let text = "I've fixed the bug in line 42. The test passes now and everything looks good."
        let msg = ClaudeMessage(
            role: "assistant", model: nil,
            contentBlocks: [
                ClaudeContentBlock(type: "text", text: text, toolName: nil, toolId: nil, toolInput: nil)
            ],
            stopReason: "end_turn"
        )
        XCTAssertFalse(ClaudeProvider.isTextAskingQuestion(msg))
    }

    func testTextNotAQuestionEmptyContent() {
        let msg = ClaudeMessage(
            role: "assistant", model: nil,
            contentBlocks: nil,
            stopReason: "end_turn"
        )
        XCTAssertFalse(ClaudeProvider.isTextAskingQuestion(msg))
    }

    func testTextQuestionDetectsWaitingForUserAfter20s() {
        // end_turn + text question + age > 20s → .waitingForUser
        let now = Date()
        let text = "Which approach do you prefer?\n\n1. Option A\n2. Option B"
        let entries = [
            ClaudeJSONLEntry(
                type: "assistant", sessionId: "s1",
                timestamp: now.addingTimeInterval(-30),
                cwd: nil, gitBranch: nil, version: nil, permissionMode: nil,
                message: ClaudeMessage(
                    role: "assistant", model: nil,
                    contentBlocks: [
                        ClaudeContentBlock(type: "text", text: text, toolName: nil, toolId: nil, toolInput: nil)
                    ],
                    stopReason: "end_turn"
                )
            )
        ]
        let activity = ClaudeProvider.determineActivity(from: entries, now: now)
        XCTAssertEqual(activity, .waitingForUser)
    }

    func testTextQuestionIdleWithin20s() {
        // end_turn + text question + age < 20s → .idle (avoid streaming flicker)
        let now = Date()
        let text = "Which approach do you prefer?"
        let entries = [
            ClaudeJSONLEntry(
                type: "assistant", sessionId: "s1",
                timestamp: now.addingTimeInterval(-5),
                cwd: nil, gitBranch: nil, version: nil, permissionMode: nil,
                message: ClaudeMessage(
                    role: "assistant", model: nil,
                    contentBlocks: [
                        ClaudeContentBlock(type: "text", text: text, toolName: nil, toolId: nil, toolInput: nil)
                    ],
                    stopReason: "end_turn"
                )
            )
        ]
        let activity = ClaudeProvider.determineActivity(from: entries, now: now)
        XCTAssertEqual(activity, .idle)
    }
}
