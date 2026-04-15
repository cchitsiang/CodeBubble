import AppKit
import CodeBubbleCore
import os.log
import SQLite3

private let logger = Logger(subsystem: "com.codebubble.app", category: "TerminalActivator")

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
        logger.info("[Activate] source=\(session.source, privacy: .public), cwd=\(session.cwd ?? "nil", privacy: .public), terminalBundleId=\(session.terminalBundleId ?? "nil", privacy: .public)")

        // Native app: bring the source's desktop app to front if running
        if let nativeBundleId = sourceToNativeAppBundleId[session.source],
           NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == nativeBundleId }) {
            logger.info("[Activate] Using native app: \(nativeBundleId, privacy: .public)")
            activateByBundleId(nativeBundleId)
            return
        }

        let projectName = session.projectDisplayName
        dbgLog("[Activate] cwd=\(session.cwd ?? "nil") projectName=\(projectName ?? "nil") terminalBundleId=\(session.terminalBundleId ?? "nil")")

        // terminalBundleId=nil means the session is inside tmux — the Claude process's parent
        // is the tmux server (a background daemon), so process-tree detection can't reach the
        // terminal app. Only attempt tmux jump in this case.
        let bundleId: String?
        if session.terminalBundleId == nil {
            // terminalBundleId=nil → session is inside tmux (Claude's parent is the tmux server).
            // Find the pane, then check whether a Ghostty client is already attached.
            // If yes → switch that client and raise Ghostty.
            // If no  → open a new Ghostty window via attach-session.
            if let pane = findTmuxPane(cwd: session.cwd, projectName: projectName) {
                dbgLog("[Activate] tmux pane found: \(pane.sessionName) ghosttyClient=\(findGhosttyClient(socketPath: pane.socketPath) ?? "none")")
                if let ghosttyTty = findGhosttyClient(socketPath: pane.socketPath) {
                    // Switch the Ghostty client to the target pane
                    let target = "\(pane.sessionId):\(pane.windowId).\(pane.paneId)"
                    guard let tmux = findBinary("tmux") else { return }
                    _ = runProcess(tmux, args: ["-S", pane.socketPath, "switch-client", "-c", ghosttyTty, "-t", target])
                    _ = runProcess(tmux, args: ["-S", pane.socketPath, "select-window", "-t", "\(pane.sessionId):\(pane.windowId)"])
                    _ = runProcess(tmux, args: ["-S", pane.socketPath, "select-pane", "-t", target])
                    dbgLog("[Activate] switched Ghostty client \(ghosttyTty) to \(target)")
                    activateGhostty(cwd: session.cwd, sessionId: nil, source: session.source)
                } else {
                    dbgLog("[Activate] no Ghostty client — openTmuxAttachInNewTab \(pane.sessionName)")
                    openTmuxAttachInNewTab(socketPath: pane.socketPath, sessionName: pane.sessionName, bundleId: "com.mitchellh.ghostty")
                }
            } else {
                dbgLog("[Activate] no tmux pane found — opening Ghostty")
                activateByBundleId("com.mitchellh.ghostty")
            }
            return
        } else {
            bundleId = session.terminalBundleId
        }

        dbgLog("[Activate] terminal switch bundleId=\(bundleId ?? "nil")")

        switch bundleId {
        case "com.mitchellh.ghostty":
            dbgLog("[Activate] → activateGhostty cwd=\(session.cwd ?? "nil")")
            activateGhostty(cwd: session.cwd, sessionId: sessionId, source: session.source)
        case "com.googlecode.iterm2":
            activateITermByCwd(cwd: session.cwd)
        case "com.apple.Terminal":
            activateTerminalAppByCwd(cwd: session.cwd)
        case "dev.warp.Warp-Stable":
            activateWarpByCwd(cwd: session.cwd)
        case "com.github.wez.wezterm", "fun.tw93.kaku":
            activateWezTermByCwd(cwd: session.cwd)
        case "net.kovidgoyal.kitty":
            activateKittyByCwd(cwd: session.cwd, source: session.source)
        case let id? where Self.vscodeFamilyBundleIds.contains(id):
            activateVSCodeFamily(cwd: session.cwd, bundleId: id)
        default:
            if let id = bundleId {
                activateByBundleId(id)
            } else {
                bringToFront(detectRunningTerminal())
            }
        }
    }

    private static let vscodeFamilyBundleIds: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf",
        "com.trae.app",
    ]

    private static let vscodeFamilyCLI: [String: String] = [
        "com.microsoft.VSCode": "code",
        "com.microsoft.VSCodeInsiders": "code-insiders",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.exafunction.windsurf": "windsurf",
        "com.trae.app": "trae",
    ]

    private static func detectRunningTerminalBundleId() -> String? {
        let termName = detectRunningTerminal().lowercased()
        return knownTerminals.first(where: { termName.contains($0.name.lowercased()) })?.bundleId
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

    // MARK: - Warp (SQLite-based pane resolution)

    /// Warp's SQLite DB path (sandboxed Group Container).
    private static var warpDBPath: String {
        NSHomeDirectory()
            + "/Library/Group Containers/2BBY89MBSN.dev.warp"
            + "/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"
    }

    private static func activateWarpByCwd(cwd: String?) {
        logger.info("[WarpJump] activateWarpByCwd called, cwd=\(cwd ?? "nil", privacy: .public)")

        guard let cwd = cwd, !cwd.isEmpty else {
            logger.warning("[WarpJump] No CWD — falling back to plain activate")
            activateByBundleId("dev.warp.Warp-Stable")
            return
        }

        // Resolve target tab index from SQLite synchronously (fast — local DB read)
        logger.info("[WarpJump] Looking up tab index for cwd=\(cwd, privacy: .public)")
        guard let targetIndex = warpTabIndex(forCwd: cwd) else {
            logger.warning("[WarpJump] warpTabIndex returned nil — CWD not found in SQLite")
            activateByBundleId("dev.warp.Warp-Stable")
            return
        }

        let tabNumber = targetIndex + 1  // 1-based for ⌘1-⌘9
        logger.info("[WarpJump] Found tab index=\(targetIndex), tabNumber=\(tabNumber)")

        guard tabNumber >= 1 && tabNumber <= 9 else {
            logger.warning("[WarpJump] tabNumber \(tabNumber) out of ⌘1-⌘9 range")
            activateByBundleId("dev.warp.Warp-Stable")
            return
        }

        let currentIndex = warpActiveTabIndex()
        logger.info("[WarpJump] Current active tab index=\(currentIndex), target=\(targetIndex)")

        if currentIndex == targetIndex {
            logger.info("[WarpJump] Already on target tab — just activating")
            activateByBundleId("dev.warp.Warp-Stable")
            return
        }

        // Send ⌘+N directly to Warp's PID via CGEventPostToPid. This function
        // is marked "obsoleted" in Swift headers but still exists in CoreGraphics.
        // We call it via dlsym to bypass the compiler restriction. This delivers
        // keystrokes directly to the target process regardless of focus state.
        logger.info("[WarpJump] Will send ⌘\(tabNumber) via CGEventPostToPid")

        let keyCodes: [Int: UInt16] = [
            1: 18, 2: 19, 3: 20, 4: 21, 5: 23,
            6: 22, 7: 26, 8: 28, 9: 25,
        ]
        guard let kc = keyCodes[tabNumber] else {
            logger.error("[WarpJump] No key code for tab \(tabNumber)")
            return
        }

        guard let warp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "dev.warp.Warp-Stable"
        }) else {
            logger.error("[WarpJump] Warp not running")
            return
        }

        let warpPid = warp.processIdentifier
        if warp.isHidden { warp.unhide() }
        warp.activate()

        DispatchQueue.global(qos: .userInitiated).async {
            postKeystrokeToPid(pid: warpPid, keyCode: kc, commandDown: true)
            logger.info("[WarpJump] CGEventPostToPid sent ⌘\(tabNumber) to PID \(warpPid)")
        }
    }


    /// Find the 0-based tab index for a CWD in Warp's SQLite.
    private static func warpTabIndex(forCwd cwd: String) -> Int? {
        guard let db = warpOpenDB() else {
            logger.error("[WarpJump] Failed to open Warp SQLite DB at \(warpDBPath, privacy: .public)")
            return nil
        }
        defer { sqlite3_close(db) }

        let resolved = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        let cwds = Array(Set([cwd, resolved]))
        logger.info("[WarpJump] Searching SQLite for CWDs: \(cwds, privacy: .public)")

        for c in cwds {
            // Deprioritize the currently active tab so we jump to a DIFFERENT tab
            // with the same CWD. Among non-active tabs, prefer the oldest pane (ASC)
            // which is typically where the long-running session lives.
            let sql = """
            SELECT t.id - (SELECT MIN(t2.id) FROM tabs t2 WHERE t2.window_id = t.window_id) as tab_index
            FROM terminal_panes tp
            JOIN pane_nodes pn ON pn.id = tp.id
            JOIN tabs t ON t.id = pn.tab_id
            JOIN windows w ON w.id = t.window_id
            WHERE tp.cwd = ?
            ORDER BY
              CASE WHEN (t.id - (SELECT MIN(t2.id) FROM tabs t2 WHERE t2.window_id = t.window_id)) = w.active_tab_index
                   THEN 1 ELSE 0 END,
              tp.id ASC
            LIMIT 1
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("[WarpJump] SQL prepare failed for cwd=\(c, privacy: .public)")
                continue
            }
            defer { sqlite3_finalize(stmt) }
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, c, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let idx = Int(sqlite3_column_int(stmt, 0))
                logger.info("[WarpJump] Found match: cwd=\(c, privacy: .public) → tab_index=\(idx)")
                return idx
            } else {
                logger.info("[WarpJump] No match for cwd=\(c, privacy: .public)")
            }
        }

        // Dump all pane CWDs for debugging
        let dumpSql = "SELECT tp.cwd FROM terminal_panes tp LIMIT 20"
        var dumpStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, dumpSql, -1, &dumpStmt, nil) == SQLITE_OK {
            var allCwds: [String] = []
            while sqlite3_step(dumpStmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(dumpStmt, 0) {
                    allCwds.append(String(cString: cStr))
                }
            }
            sqlite3_finalize(dumpStmt)
            logger.info("[WarpJump] All pane CWDs in DB: \(allCwds, privacy: .public)")
        }

        return nil
    }

    /// Read the current active tab index from Warp's windows table.
    private static func warpActiveTabIndex() -> Int {
        guard let db = warpOpenDB() else { return 0 }
        defer { sqlite3_close(db) }

        let sql = "SELECT active_tab_index FROM windows ORDER BY id DESC LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    private static func warpOpenDB() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(warpDBPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return nil }
        return db
    }

    // MARK: - VS Code / Cursor / Windsurf / Trae

    private static func activateVSCodeFamily(cwd: String?, bundleId: String) {
        guard let cwd = cwd, !cwd.isEmpty,
              let cli = vscodeFamilyCLI[bundleId] else {
            activateByBundleId(bundleId)
            return
        }
        // Use CLI to open the workspace in the existing window
        DispatchQueue.global(qos: .userInitiated).async {
            if let bin = findBinary(cli) {
                _ = runProcess(bin, args: ["-r", cwd])
            } else {
                DispatchQueue.main.async { activateByBundleId(bundleId) }
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
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
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

    // MARK: - tmux

    private struct TmuxPane {
        let paneId: String
        let cwd: String
        let sessionId: String
        let windowId: String
        let sessionName: String
        let socketPath: String
    }

    private struct TmuxClient {
        let clientTty: String
        let sessionId: String
    }

    /// Find all panes across all tmux sessions, using the default socket.
    private static func listTmuxPanes() -> [TmuxPane]? {
        guard let tmux = findBinary("tmux") else {
            dbgLog("[listTmuxPanes] tmux binary not found")
            return nil
        }
        let fmt = "#{pane_id}\t#{pane_current_path}\t#{session_id}\t#{window_id}\t#{session_name}\t#{socket_path}"
        guard let data = runProcess(tmux, args: ["list-panes", "-a", "-F", fmt]),
              let output = String(data: data, encoding: .utf8) else {
            dbgLog("[listTmuxPanes] runProcess failed (tmux not running or error)")
            return nil
        }
        let panes = output.split(separator: "\n").compactMap { line -> TmuxPane? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 6 else { return nil }
            return TmuxPane(
                paneId: String(parts[0]),
                cwd: String(parts[1]),
                sessionId: String(parts[2]),
                windowId: String(parts[3]),
                sessionName: String(parts[4]),
                socketPath: String(parts[5])
            )
        }
        dbgLog("[listTmuxPanes] found \(panes.count) panes: \(panes.map { "\($0.sessionName):\($0.cwd)" }.joined(separator: ", "))")
        return panes
    }

    /// List attached clients for a tmux server identified by its socket path.
    private static func listTmuxClients(socketPath: String) -> [TmuxClient]? {
        guard let tmux = findBinary("tmux") else { return nil }
        let fmt = "#{client_tty}\t#{client_session}"
        guard let data = runProcess(tmux, args: ["-S", socketPath, "list-clients", "-F", fmt]),
              let output = String(data: data, encoding: .utf8) else { return nil }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            return TmuxClient(clientTty: String(parts[0]), sessionId: String(parts[1]))
        }
    }

    /// Switch the tmux client to the pane whose CWD (or session name) matches. Returns true on success.
    @discardableResult
    private static func tmuxJump(cwd: String?, projectName: String? = nil) -> Bool {
        guard let tmux = findBinary("tmux") else { return false }
        guard let panes = listTmuxPanes(), !panes.isEmpty else { return false }

        var pane: TmuxPane?

        // Session name match has highest priority — most precise when multiple panes share a CWD
        if let projectName, !projectName.isEmpty {
            pane = panes.first(where: { $0.sessionName == projectName })
        }

        if pane == nil, let cwd, !cwd.isEmpty {
            let resolvedCwd = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path

            // Exact CWD match
            pane = panes.first(where: { $0.cwd == cwd || $0.cwd == resolvedCwd })

            // Ancestor match: pane sits at a parent of the session CWD
            if pane == nil {
                let candidates = panes.filter { p in
                    cwd.hasPrefix(p.cwd + "/") || resolvedCwd.hasPrefix(p.cwd + "/")
                }
                pane = candidates.max(by: { $0.cwd.count < $1.cwd.count })
            }
        }

        guard let pane else {
            dbgLog("[tmuxJump] No pane found cwd=\(cwd ?? "nil") projectName=\(projectName ?? "nil")")
            return false
        }

        let target = "\(pane.sessionId):\(pane.windowId).\(pane.paneId)"
        dbgLog("[tmuxJump] Found pane=\(target) socket=\(pane.socketPath) sessionName=\(pane.sessionName)")

        let clients = listTmuxClients(socketPath: pane.socketPath) ?? []
        // Prefer a client already attached to the same session, then any client
        let client = clients.first(where: { $0.sessionId == pane.sessionId }) ?? clients.first

        // switch-client moves the client's focus to our target pane
        var switchArgs = ["-S", pane.socketPath, "switch-client"]
        if let tty = client?.clientTty {
            logger.info("[tmuxJump] Using client_tty=\(tty, privacy: .public)")
            switchArgs += ["-c", tty]
        }
        switchArgs += ["-t", target]
        _ = runProcess(tmux, args: switchArgs)

        // select-window + select-pane ensure the pane is visible even if switch-client
        // targeted a different session (or no client was found)
        _ = runProcess(tmux, args: ["-S", pane.socketPath, "select-window", "-t", "\(pane.sessionId):\(pane.windowId)"])
        _ = runProcess(tmux, args: ["-S", pane.socketPath, "select-pane", "-t", target])

        logger.info("[tmuxJump] Done — switched to \(target, privacy: .public)")
        return true
    }

    /// Walk up the process tree from `pid` looking for a known terminal app bundle.
    private static func walkPidTreeForTerminal(_ startPid: pid_t) -> String? {
        var p = startPid
        for _ in 0..<12 {
            guard let data = runProcess("/bin/ps", args: ["-o", "ppid=,comm=", "-p", "\(p)"]),
                  let out = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !out.isEmpty else { break }
            let parts = out.split(separator: " ", maxSplits: 1)
            guard let ppid = parts.first.flatMap({ pid_t($0) }) else { break }
            let comm = parts.count > 1 ? String(parts[1]) : ""
            // Match .app bundle path
            if comm.contains(".app/") || comm.hasSuffix(".app") {
                let endIdx = (comm.range(of: ".app/")?.lowerBound
                    ?? comm.range(of: ".app")?.lowerBound) ?? comm.endIndex
                let appPath = String(comm[..<endIdx]) + ".app"
                if let bundle = Bundle(path: appPath), let bid = bundle.bundleIdentifier {
                    return bid
                }
            }
            // Match known terminal process names
            let lower = comm.lowercased()
            for (name, bundleId) in knownTerminals {
                if lower.contains(name.lowercased()) { return bundleId }
            }
            p = ppid
            if ppid <= 1 { break }
        }
        return nil
    }

    /// Find the best matching tmux pane for a session (session name > exact CWD > ancestor CWD).
    private static func findTmuxPane(cwd: String?, projectName: String?) -> TmuxPane? {
        guard let panes = listTmuxPanes(), !panes.isEmpty else { return nil }
        // 1. Session name (most precise — avoids CWD collisions)
        if let name = projectName, !name.isEmpty,
           let pane = panes.first(where: { $0.sessionName == name }) { return pane }
        guard let cwd, !cwd.isEmpty else { return nil }
        let resolved = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        // 2. Exact CWD
        if let pane = panes.first(where: { $0.cwd == cwd || $0.cwd == resolved }) { return pane }
        // 3. Ancestor CWD (pane sits at a parent directory of the session CWD)
        return panes
            .filter { cwd.hasPrefix($0.cwd + "/") || resolved.hasPrefix($0.cwd + "/") }
            .max(by: { $0.cwd.count < $1.cwd.count })
    }

    /// Find a tmux session by exact name match. Returns the first pane in that session.
    private static func findTmuxSessionByName(_ name: String) -> TmuxPane? {
        guard let panes = listTmuxPanes() else { return nil }
        return panes.first(where: { $0.sessionName == name })
    }

    /// Return the TTY of the first tmux client that is running inside Ghostty.
    private static func findGhosttyClient(socketPath: String) -> String? {
        let clients = listTmuxClients(socketPath: socketPath) ?? []
        for client in clients {
            let ttyShort = client.clientTty.replacingOccurrences(of: "/dev/", with: "")
            guard let data = runProcess("/bin/ps", args: ["-t", ttyShort, "-o", "pid="]),
                  let out = String(data: data, encoding: .utf8) else { continue }
            for pidLine in out.split(separator: "\n") {
                guard let pid = pid_t(pidLine.trimmingCharacters(in: .whitespaces)) else { continue }
                if let bid = walkPidTreeForTerminal(pid), bid == "com.mitchellh.ghostty" {
                    return client.clientTty
                }
            }
        }
        return nil
    }

    /// Open a new terminal tab/window and run `tmux attach-session` inside it.
    private static func openTmuxAttachInNewTab(socketPath: String, sessionName: String, bundleId: String?) {
        guard let tmux = findBinary("tmux") else { return }
        logger.info("[tmuxAttach] Opening new tab: \(tmux, privacy: .public) -S \(socketPath, privacy: .public) attach-session -t \(sessionName, privacy: .public)")

        switch bundleId {
        case "com.googlecode.iterm2":
            let attachCmd = escapeAppleScript("\(tmux) -S \(socketPath) attach-session -t \(sessionName)")
            let script = """
            tell application "iTerm2"
                tell current window
                    create tab with default profile
                    tell current session
                        write text "\(attachCmd)"
                    end tell
                end tell
            end tell
            """
            runAppleScript(script)

        case "com.apple.Terminal":
            let attachCmd = escapeAppleScript("\(tmux) -S \(socketPath) attach-session -t \(sessionName)")
            let script = """
            tell application "Terminal"
                do script "\(attachCmd)"
                activate
            end tell
            """
            runAppleScript(script)

        default:
            // Ghostty (and unknown terminals): open a new window running the attach command.
            // Each argument must be passed separately — Ghostty's -e flag does not accept
            // a single shell string; it takes the executable followed by its arguments.
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-na", "Ghostty.app", "--args",
                                   "-e", tmux, "-S", socketPath, "attach-session", "-t", sessionName]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try? proc.run()
            }
        }
    }

    // MARK: - Debug trace

    private static let dbgLogPath = "/tmp/cb-trace.log"

    private static func dbgLog(_ msg: String) {
        #if DEBUG
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: dbgLogPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: dbgLogPath, contents: data)
            }
        }
        #endif
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

    /// Post a keystroke directly to a specific PID using CGEventPostToPid.
    /// The function is "obsoleted" in Swift headers but still works — called via dlsym.
    private static func postKeystrokeToPid(pid: pid_t, keyCode: UInt16, commandDown: Bool) {
        typealias PostToPidFn = @convention(c) (pid_t, CGEvent?) -> Void

        guard let cgLib = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(cgLib, "CGEventPostToPid") else {
            logger.error("[WarpJump] dlsym CGEventPostToPid failed")
            return
        }
        let postToPid = unsafeBitCast(sym, to: PostToPidFn.self)

        let src = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else {
            logger.error("[WarpJump] Failed to create CGEvent")
            return
        }

        if commandDown {
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
        }

        postToPid(pid, keyDown)
        postToPid(pid, keyUp)
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
