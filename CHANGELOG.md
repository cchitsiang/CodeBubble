# Changelog

## [1.2.4] — 2026-04-15

### Added
- **Warp tab jump via SQLite CWD-to-pane resolution**: reads Warp's internal SQLite DB to find the exact tab matching a session's CWD, then jumps directly to it with ⌘N keystroke
- **Tab-level terminal jump**: uses the detected terminal bundle ID to route activation through terminal-specific jump strategies (Warp SQLite, iTerm2 AppleScript, etc.)
- **Real terminal app icon detection**: resolves the actual terminal emulator from the process tree and displays its icon in session cards via TerminalBadge
- **TerminalBadge shows terminal icon only**: removed the source label text, showing only the detected terminal's app icon for a cleaner look

### Fixed
- **Warp tab jump uses direct ⌘N keystroke** via `CGEventPostToPid` instead of cycling through tabs — reliable regardless of tab count or ordering
- **Correct Warp SQLite column names** for tab jump queries (`terminal_panes`, `pane_nodes`, `tabs`, `windows`)
- **Reduced text question delay** from 20s to 3s for faster question detection in the notch panel
- **Subagent approval gating**: checks `permissionMode` in subagent JSONL before flagging tools as waiting for approval (prevents false positives for `bypassPermissions` subagents)

## [1.2.3] — 2026-04-15

### Fixed
- `Set<String>()` initializer for `@Observable` compatibility (was causing compile error on older Xcode)
- Completion card only fires once per idle period (prevents repeated completion toasts)

## [1.2.2] — 2026-04-15

### Added
- **Accessibility change listener** via `DistributedNotificationCenter` — auto-detects when user grants Accessibility permission and re-registers global shortcuts without restart

### Fixed
- Accessibility prompt shown only once on first launch (no longer re-prompts every launch)
- Accessibility banner uses 2s timer recheck for responsive UI updates
- Silent Accessibility check — no system dialog on every app launch
- Proper code signing in build-dmg.sh (Developer ID certs only, not Apple Development)
- Stable code signing identifier for debug builds

## [1.2.1] — 2026-04-15

### Fixed
- AppIcon.icns included in release DMG (was missing from `build-dmg.sh` copy step)

## [1.2.0] — 2026-04-15

### Added
- **Subagent approval detection**: scan subagent JSONL (`sessionId/subagents/agent-*.jsonl`) when main session has Agent/Task tool pending to detect subagent tools waiting for approval
- **Subagent auto-approve in hook server**: tools with `agent_id` in the hook payload are auto-approved (parent already approved spawning the subagent)
- **Bypass permission auto-approve**: hooks with `permission_mode: bypassPermissions` or `acceptEdits` are auto-approved immediately
- **Text question detection** (c9watch heuristic): assistant responses ending with `?` (or containing `?` in last 5 lines) detected as waiting for user answer after 20s
- **Peer disconnect monitoring**: when the bridge process dies (Claude killed/timed out the hook), orphaned approval/question queue entries are cleaned up and the card dismisses
- **Queue count badge** on ApprovalBar (`1/N`) when multiple approvals are pending
- **Stale hook drain**: when a new hook arrives for a session, old pending hooks for that session are auto-resolved (prevents duplicate/stale queue entries)
- Debug payload dump to `/tmp/hook-payload.json` in debug builds

### Changed
- **PixelButton uses `onTapGesture`** instead of `Button(action:)` — fixes taps not registering in `nonactivatingPanel` windows
- Auto-approve list in hook server matches upstream: only internal meta-tools (Task*, Todo*, PlanMode), not Read/Glob/Grep
- Passive approval detection uses `recentlyResolvedAnyApproval` (5s window) to suppress flash during active hook flow, while remaining available for app restart scenarios
- "Always" approval response format matches upstream exactly (`type: addRules`, `destination: session`)

### Fixed
- Legacy `codebubble-hook.sh` entries cleaned from ALL hook events on install (was only cleaning PermissionRequest, leaving 12 stale entries causing "No such file or directory" errors)
- Completion card no longer overwrites approval/question cards
- Fast completions (< 3s response) detected via `lastActivity` timestamp tracking
- Approval bar properly dismissed after Allow/Deny (was re-surfacing due to hover + JSONL re-detection race)
- Hook approval state not overwritten by provider polls (both approval and question queues protected)
- Question bar dismissed after answering with proper status transition to `.thinking`
- Skip question sets status to `.thinking` and clears pending info
- Session card tap shows QuestionBar when question is pending
- "Answer in Terminal" label for AskUserQuestion fallback (was "Approve in Terminal")
- Smooth dismiss transitions with `NotchAnimation.close`
- Visual feedback on option select (✓ checkmark + accent background, 300ms delay before submit)

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
