import AppKit
import CodeBubbleCore

/// Activates the terminal window/tab associated with a session.
/// Since we no longer have terminal metadata from hooks, this uses CWD-based
/// heuristics to find the right terminal window, or falls back to the most
/// recently active terminal app.
struct TerminalActivator {
    private static let knownTerminals: [(name: String, bundleId: String)] = [
        ("Ghostty", "com.mitchellh.ghostty"),
        ("iTerm2", "com.googlecode.iterm2"),
        ("WezTerm", "com.github.wez.wezterm"),
        ("kitty", "net.kovidgoyal.kitty"),
        ("Alacritty", "org.alacritty"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("Terminal", "com.apple.Terminal"),
    ]

    /// Source-specific native app bundle IDs for desktop apps
    private static let sourceToNativeAppBundleId: [String: String] = [
        "codex": "com.openai.codex",
        "cursor": "com.todesktop.230313mzl4w4u92",
        "opencode": "ai.opencode.desktop",
    ]

    static func activate(session: SessionSnapshot, sessionId: String? = nil) {
        // Native app: bring the source's desktop app to front if running
        if let nativeBundleId = sourceToNativeAppBundleId[session.source],
           NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == nativeBundleId }) {
            activateByBundleId(nativeBundleId)
            return
        }

        // Try to find a terminal with the matching CWD
        let termApp = detectRunningTerminal()
        let lower = termApp.lowercased()

        if lower == "ghostty" {
            activateGhostty(cwd: session.cwd, sessionId: sessionId, source: session.source)
            return
        }

        if lower.contains("iterm") {
            activateITermByCwd(cwd: session.cwd)
            return
        }

        if lower.contains("terminal") {
            activateTerminalAppByCwd(cwd: session.cwd)
            return
        }

        if lower.contains("wezterm") || lower.contains("wez") {
            activateWezTermByCwd(cwd: session.cwd)
            return
        }

        if lower.contains("kitty") {
            activateKittyByCwd(cwd: session.cwd, source: session.source)
            return
        }

        // Fallback: just bring the terminal to front
        bringToFront(termApp)
    }

    // MARK: - Ghostty

    private static func activateGhostty(cwd: String?, sessionId: String? = nil, source: String = "claude") {
        guard let cwd = cwd, !cwd.isEmpty else { bringToFront("Ghostty"); return }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }) else {
            bringToFront("Ghostty")
            return
        }
        if app.isHidden { app.unhide() }
        app.activate()

        let escapedCwd = escapeAppleScript(cwd)
        let resolvedCwd = escapeAppleScript(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path)
        let dirName = escapeAppleScript((cwd as NSString).lastPathComponent)
        let keyword = escapeAppleScript(source)

        let idFilter: String
        if let sid = sessionId, !sid.isEmpty {
            let escapedSid = escapeAppleScript(String(sid.prefix(8)))
            idFilter = """
                repeat with t in matches
                    if name of t contains "\(escapedSid)" then
                        focus t
                        activate
                        return
                    end if
                end repeat
            """
        } else {
            idFilter = ""
        }

        let script = """
        tell application "Ghostty"
            set allTerms to terminals
            set matches to {}
            set cwd1 to "\(escapedCwd)"
            set cwd2 to "\(resolvedCwd)"
            if cwd1 is not "" then
                try
                    set matches to (every terminal whose working directory is cwd1)
                end try
            end if
            if (count of matches) = 0 and cwd2 is not "" and cwd2 is not cwd1 then
                try
                    set matches to (every terminal whose working directory is cwd2)
                end try
            end if
            if (count of matches) = 0 then
                set dirName to "\(dirName)"
                repeat with t in allTerms
                    try
                        set tname to (name of t as text)
                        if (cwd1 is not "" and tname contains cwd1) or (dirName is not "" and tname contains dirName) then
                            set end of matches to t
                        end if
                    end try
                end repeat
            end if
            \(idFilter)
            repeat with t in matches
                if name of t contains "\(keyword)" then
                    focus t
                    activate
                    return
                end if
            end repeat
            if (count of matches) > 0 then
                focus (item 1 of matches)
            end if
            activate
        end tell
        """
        runOsaScript(script)
    }

    // MARK: - iTerm2

    private static func activateITermByCwd(cwd: String?) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        }) else {
            bringToFront("iTerm2")
            return
        }
        if app.isHidden { app.unhide() }
        app.activate()
        guard let cwd = cwd, !cwd.isEmpty else { return }
        let dirName = (cwd as NSString).lastPathComponent
        let script = """
        try
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                if name of s contains "\(escapeAppleScript(dirName))" or path of s contains "\(escapeAppleScript(dirName))" then
                                    select t
                                    select s
                                    set index of w to 1
                                    return
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat
            end tell
        end try
        """
        runAppleScript(script)
    }

    // MARK: - Terminal.app

    private static func activateTerminalAppByCwd(cwd: String?) {
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.apple.Terminal"
        }) else {
            bringToFront("Terminal")
            return
        }
        guard let cwd = cwd, !cwd.isEmpty else { bringToFront("Terminal"); return }
        let dirName = escapeAppleScript((cwd as NSString).lastPathComponent)
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if custom title of t contains "\(dirName)" then
                            if miniaturized of w then set miniaturized of w to false
                            set selected tab of w to t
                            set index of w to 1
                            activate
                            return
                        end if
                    end try
                end repeat
            end repeat
            activate
        end tell
        """
        runAppleScript(script)
    }

    // MARK: - WezTerm

    private static func activateWezTermByCwd(cwd: String?) {
        bringToFront("WezTerm")
        guard let bin = findBinary("wezterm"), let cwd = cwd else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let json = runProcess(bin, args: ["cli", "list", "--format", "json"]),
                  let panes = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return }
            let cwdUrl = "file://" + cwd
            if let tabId = panes.first(where: {
                guard let paneCwd = $0["cwd"] as? String else { return false }
                return paneCwd == cwdUrl || paneCwd == cwd
            })?["tab_id"] as? Int {
                _ = runProcess(bin, args: ["cli", "activate-tab", "--tab-id", "\(tabId)"])
            }
        }
    }

    // MARK: - kitty

    private static func activateKittyByCwd(cwd: String?, source: String = "claude") {
        bringToFront("kitty")
        guard let bin = findBinary("kitten"), let cwd = cwd, !cwd.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if runProcess(bin, args: ["@", "focus-tab", "--match", "cwd:\(cwd)"]) == nil {
                _ = runProcess(bin, args: ["@", "focus-tab", "--match", "title:\(source)"])
            }
        }
    }

    // MARK: - Activate by bundle ID

    private static func activateByBundleId(_ bundleId: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) {
            if app.isHidden { app.unhide() }
            app.activate()
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Generic (bring app to front)

    private static func bringToFront(_ termApp: String) {
        let name: String
        let lower = termApp.lowercased()
        if lower == "ghostty" { name = "Ghostty" }
        else if lower.contains("iterm") { name = "iTerm2" }
        else if lower.contains("terminal") || lower.contains("apple_terminal") { name = "Terminal" }
        else if lower.contains("wezterm") || lower.contains("wez") { name = "WezTerm" }
        else if lower.contains("alacritty") || lower.contains("lacritty") { name = "Alacritty" }
        else if lower.contains("kitty") { name = "kitty" }
        else if lower.contains("warp") { name = "Warp" }
        else { name = termApp }

        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(name)
        }) {
            if app.isHidden { app.unhide() }
            app.activate()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", name]
            try? proc.run()
        }
    }

    // MARK: - Helpers

    private static func detectRunningTerminal() -> String {
        let running = NSWorkspace.shared.runningApplications
        for (name, bundleId) in knownTerminals {
            if running.contains(where: { $0.bundleIdentifier == bundleId }) {
                return name
            }
        }
        return "Terminal"
    }

    private static func runAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let script = NSAppleScript(source: source) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
            }
        }
    }

    private static func runOsaScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", source]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
        }
    }

    private static func escapeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func findBinary(_ name: String) -> String? {
        let paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private static func runProcess(_ path: String, args: [String]) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return proc.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }
}
