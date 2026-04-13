import SwiftUI
import CodeBubbleCore

// MARK: - Preview Scenario System
//
// Usage: launch with --preview <scenario> to inject mock sessions for UI development.
//   e.g.  .build/debug/CodeBubble --preview working
//
// Scenarios:
//   working     — single session actively running tools
//   completion  — session just finished
//   multi       — 3 sessions in mixed states
//   busy        — heavy workload
//   claude      — Claude CLI single session
//   codex       — Codex CLI single session
//   opencode    — OpenCode CLI single session
//   allcli      — Multiple CLIs running simultaneously
//   idle        — no sessions
//   stress      — 30 sessions for performance testing

enum PreviewScenario: String, CaseIterable {
    case working
    case completion
    case multi
    case busy
    // CLI-specific scenarios
    case claude
    case codex
    case opencode
    case allcli
    // Special states
    case idle
    // Performance stress test
    case stress
}

@MainActor
enum DebugHarness {

    /// Check launch arguments for --preview flag, return scenario if found
    static func requestedScenario() -> PreviewScenario? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--preview"), idx + 1 < args.count else { return nil }
        return PreviewScenario(rawValue: args[idx + 1])
    }

    /// Inject mock data into appState for the given scenario
    static func apply(_ scenario: PreviewScenario, to appState: AppState) {
        switch scenario {
        case .working:
            applyWorking(to: appState)
        case .completion:
            applyCompletion(to: appState)
        case .multi:
            applyMulti(to: appState)
        case .busy:
            applyBusy(to: appState)
        case .claude: applyClaude(to: appState)
        case .codex: applyCodex(to: appState)
        case .opencode: applyOpenCode(to: appState)
        case .allcli: applyAllCLI(to: appState)
        case .idle: applyIdle(to: appState)
        case .stress: applyStress(to: appState)
        }
    }

    // MARK: - Scenarios

    private static func applyWorking(to state: AppState) {
        var s = SessionSnapshot()
        s.status = .running
        s.cwd = "/Users/dev/my-project"
        s.model = "claude-sonnet-4-20250514"
        s.source = "claude"
        s.currentTool = "Edit"
        s.toolDescription = "src/components/App.tsx"
        s.lastUserPrompt = "Fix the login button styling"

        state.sessions["preview-working"] = s
        state.activeSessionId = "preview-working"
    }

    private static func applyCompletion(to state: AppState) {
        var s = SessionSnapshot()
        s.status = .idle
        s.cwd = "/Users/dev/cli-tool"
        s.model = "claude-sonnet-4-20250514"
        s.source = "claude"
        s.lastUserPrompt = "Add --verbose flag"
        s.lastAssistantMessage = "Done. Added the --verbose flag to the CLI parser with short alias -v. It enables detailed logging output throughout the pipeline."

        state.sessions["preview-completion"] = s
        state.activeSessionId = "preview-completion"
        state.surface = .completionCard(sessionId: "preview-completion")
    }

    private static func applyMulti(to state: AppState) {
        // Session 1: Claude working
        var s1 = SessionSnapshot()
        s1.status = .running
        s1.cwd = "/Users/dev/frontend"
        s1.model = "claude-sonnet-4-20250514"
        s1.source = "claude"
        s1.currentTool = "Write"
        s1.toolDescription = "src/pages/Dashboard.tsx"
        s1.lastUserPrompt = "Build the dashboard page"

        // Session 2: Codex idle
        var s2 = SessionSnapshot()
        s2.status = .idle
        s2.cwd = "/Users/dev/backend"
        s2.model = "o3"
        s2.source = "codex"
        s2.lastUserPrompt = "Optimize the query planner"
        s2.lastAssistantMessage = "Refactored the query planner to use a cost-based optimizer."

        // Session 3: OpenCode thinking
        var s3 = SessionSnapshot()
        s3.status = .thinking
        s3.cwd = "/Users/dev/mobile"
        s3.source = "opencode"
        s3.lastUserPrompt = "Fix the scroll jank"

        state.sessions["preview-multi-1"] = s1
        state.sessions["preview-multi-2"] = s2
        state.sessions["preview-multi-3"] = s3
        state.activeSessionId = "preview-multi-1"
    }

    private static func applyBusy(to state: AppState) {
        // Main Claude session
        var s1 = SessionSnapshot()
        s1.status = .running
        s1.cwd = "/Users/dev/monorepo"
        s1.model = "claude-opus-4-20250514"
        s1.source = "claude"
        s1.currentTool = "Edit"
        s1.toolDescription = "src/index.ts"
        s1.lastUserPrompt = "Migrate the entire codebase to TypeScript 5.5"

        // Codex session
        var s2 = SessionSnapshot()
        s2.status = .thinking
        s2.cwd = "/Users/dev/data-pipeline"
        s2.model = "o3"
        s2.source = "codex"
        s2.lastUserPrompt = "Profile the ETL bottleneck"

        // OpenCode session waiting for user
        var s3 = SessionSnapshot()
        s3.status = .waitingForUser
        s3.cwd = "/Users/dev/infra"
        s3.model = "gpt-4.1"
        s3.source = "opencode"
        s3.currentTool = "Bash"
        s3.toolDescription = "terraform apply"
        s3.lastUserPrompt = "Deploy the staging env"

        state.sessions["preview-busy-1"] = s1
        state.sessions["preview-busy-2"] = s2
        state.sessions["preview-busy-3"] = s3
        state.activeSessionId = "preview-busy-1"
    }

    // MARK: - CLI-Specific Scenarios

    private static func applyClaude(to state: AppState) {
        var s = SessionSnapshot()
        s.status = .running
        s.cwd = "/tmp/demo-claude"
        s.model = "claude-opus-4-20250514"
        s.source = "claude"
        s.currentTool = "Edit"
        s.toolDescription = "src/main.swift"
        s.lastUserPrompt = "Refactor the networking layer"
        state.sessions["preview-claude"] = s
        state.activeSessionId = "preview-claude"
    }

    private static func applyCodex(to state: AppState) {
        var s = SessionSnapshot()
        s.status = .running
        s.cwd = "/tmp/demo-codex"
        s.model = "o3"
        s.source = "codex"
        s.currentTool = "Bash"
        s.toolDescription = "npm test"
        s.lastUserPrompt = "Fix the failing unit tests"
        state.sessions["preview-codex"] = s
        state.activeSessionId = "preview-codex"
    }

    private static func applyOpenCode(to state: AppState) {
        var s = SessionSnapshot()
        s.status = .running
        s.cwd = "/tmp/demo-opencode"
        s.model = "gpt-4.1"
        s.source = "opencode"
        s.currentTool = "Bash"
        s.toolDescription = "npm test"
        s.lastUserPrompt = "Run the test suite"
        state.sessions["preview-opencode"] = s
        state.activeSessionId = "preview-opencode"
    }

    private static func applyAllCLI(to state: AppState) {
        var s1 = SessionSnapshot()
        s1.status = .running
        s1.cwd = "/tmp/demo-claude"
        s1.model = "claude-opus-4-20250514"
        s1.source = "claude"
        s1.currentTool = "Edit"
        s1.toolDescription = "src/main.ts"
        s1.lastUserPrompt = "Migrate to TypeScript"

        var s2 = SessionSnapshot()
        s2.status = .running
        s2.cwd = "/tmp/demo-codex"
        s2.model = "o3"
        s2.source = "codex"
        s2.currentTool = "Bash"
        s2.toolDescription = "cargo build"
        s2.lastUserPrompt = "Build the Rust project"

        var s3 = SessionSnapshot()
        s3.status = .thinking
        s3.cwd = "/tmp/demo-opencode"
        s3.model = "gpt-4.1"
        s3.source = "opencode"
        s3.lastUserPrompt = "Run test suite"

        state.sessions["preview-allcli-1"] = s1
        state.sessions["preview-allcli-2"] = s2
        state.sessions["preview-allcli-3"] = s3
        state.activeSessionId = "preview-allcli-1"
    }

    // MARK: - Idle (no sessions)

    private static func applyIdle(to state: AppState) {
        state.sessions.removeAll()
        state.activeSessionId = nil
        state.surface = .collapsed
    }

    // MARK: - Stress Test (30 sessions)

    private static func applyStress(to state: AppState) {
        let sources = ["claude", "codex", "opencode"]
        let statuses: [AgentStatus] = [.running, .thinking, .idle, .waitingForUser]
        let tools = ["Edit", "Read", "Bash", "Write", "Grep"]
        let projects = ["frontend", "backend", "api", "mobile", "infra", "docs", "cli", "sdk", "web", "core"]

        for i in 0..<30 {
            var s = SessionSnapshot()
            s.status = statuses[i % statuses.count]
            s.cwd = "/tmp/stress-\(projects[i % projects.count])-\(i)"
            s.model = i % 3 == 0 ? "claude-opus-4-20250514" : "claude-sonnet-4-20250514"
            s.source = sources[i % sources.count]
            s.lastUserPrompt = "Task #\(i): work on \(projects[i % projects.count])"
            if s.status == .running || s.status == .thinking {
                s.currentTool = tools[i % tools.count]
                s.toolDescription = "src/module\(i).swift"
            }
            s.lastActivity = Date().addingTimeInterval(Double(-i * 30))
            state.sessions["preview-stress-\(i)"] = s
        }
        state.activeSessionId = "preview-stress-0"
    }
}
