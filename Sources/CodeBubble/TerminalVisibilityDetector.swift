import AppKit
import CodeBubbleCore

/// Detects whether a session's terminal is currently the frontmost application.
/// Used by smart-suppress to avoid expanding the panel when the user is already
/// looking at their terminal.
///
/// Since we no longer have terminal metadata from hooks (termApp, termBundleId, etc.),
/// this uses a simple heuristic: check if any known terminal app is frontmost.
struct TerminalVisibilityDetector {

    private static let knownTerminalBundleIds: Set<String> = [
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "dev.warp.Warp-Stable",
        "com.apple.Terminal",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.openai.codex",
        "ai.opencode.desktop",
    ]

    /// Fast check: is any known terminal or IDE the frontmost application?
    /// Safe to call from the main thread.
    static func isTerminalFrontmostForSession(_ session: SessionSnapshot) -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontApp.bundleIdentifier else { return false }
        return knownTerminalBundleIds.contains(bundleId)
    }
}
