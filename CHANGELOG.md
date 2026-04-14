# Changelog

## [1.1.0] — 2026-04-14

### Added
- **Hybrid approval system**: Swift bridge binary + PermissionRequest hook enables Allow/Deny/Always buttons directly in the notch panel
- **QuestionBar**: AskUserQuestion tool now shows an interactive question UI with option buttons or free-text input
- **Global shortcuts**: ⌘⇧A to approve, ⌘⇧D to deny (enabled by default)
- **Permission-aware status detection**: reads `~/.claude/settings.json` allow rules and JSONL `permissionMode` to correctly distinguish "waiting for approval" from "tool executing" (ported from c9watch)
- **SessionsExpandLink** below ApprovalBar to jump to full session list
- **Tap session card** to toggle inline last assistant message, or open ApprovalBar if approval is pending
- **Terminal icon** on each session card for explicit jump-to-terminal
- **Completion card** now shows last assistant message (up to 4 lines)
- Session grouping tabs: **STATUS** (by state) and **NEWEST** (by recency)
- New bot logo and app icon

### Changed
- Approval buttons use MioIsland-inspired palette: green Allow (#4ADE80), blue Always (#3B82F6), subtle Deny
- PixelButton style with hover effects (ported from upstream CodeIsland)
- "Processing" label renamed to "Working" everywhere
- About page updated: description, version fallback, single settings group

### Fixed
- Sessions with `bypassPermissions` or `acceptEdits` no longer show false approval prompts
- `permissionMode` read from JSONL file header (type=permission-mode entry at top of file)
- Hook approval state not overwritten by provider polls
- Pending tool_use no longer times out based on age — trusts process liveness
- User message as last JSONL entry stays "thinking" regardless of age
- Hook queue is authoritative for pending approval routing (fixes wrong session shown)
- No more "Approve in Terminal" flash before hook fires
- Panel visibility updates when activeSessionCount changes
- Stale CodeBubble instances killed on `run.sh` startup
- Pipe deadlock in CodexProvider/ClaudeProvider (read before waitUntilExit)

## [1.0.0] — 2026-04-13

### Added
- **Passive JSONL/SQLite monitoring** — replaces hook-based architecture from upstream
  - **ClaudeProvider**: watches `~/.claude/projects/*/*.jsonl`, process-centric session detection via PID files + process table scan
  - **CodexProvider**: reads `~/.codex/state_5.sqlite`, matches running processes by CWD
  - **OpenCodeProvider**: reads `~/.local/share/opencode/opencode.db`, matches running processes by CWD
- **SessionMonitor**: central 3-second polling loop across all providers
- **SessionProvider protocol**: clean abstraction for pluggable agent support
- Pixel-art mascots for each agent: ClawdView (Claude), CodexView (Codex), OpenCodeView (OpenCode)
- Accessibility permission prompt on first launch for global shortcuts
- Auto re-register shortcuts when Accessibility permission is granted
- `run.sh` dev script with R to rebuild/relaunch, Q to quit
- `release.sh` automated release script (build DMG → GitHub release → Homebrew tap)
- Homebrew distribution via `brew install --cask cchitsiang/tap/codebubble`

### Changed
- Forked from [CodeIsland](https://github.com/wxtsky/CodeIsland) by @wxtsky
- Renamed CodeIsland → CodeBubble across all files, bundle IDs, paths
- Removed support for Gemini, Cursor, Copilot, Qoder, Factory, CodeBuddy (focus on Claude, Codex, OpenCode)
- Removed hook-based infrastructure: HookServer, ConfigInstaller, codebubble-bridge, RemoteInstaller
- Removed remote SSH forwarding (RemoteManager, RemoteHost, SSHForwarder)
- Removed Turkish language support
- Simplified AppState: removed ~3,000 lines of hook/permission/question/discovery code
- Simplified SessionSnapshot to a plain data struct
- GitHub links updated to cchitsiang/CodeBubble

### Removed
- Bridge binary target (restored in 1.1.0 for approval-only use)
- Hook installation for all events (restored in 1.1.0 for PermissionRequest only)
- Permission approval/deny from panel (restored in 1.1.0)
- Question answering from panel (restored in 1.1.0)
- 9-tool CLI support (reduced to 3)
- Remote host SSH forwarding
