import Foundation
import os.log

private let log = Logger(subsystem: "com.codebubble", category: "HookInstaller")

/// Installs the codebubble-bridge binary into ~/.claude/hooks/ and registers
/// a single PermissionRequest hook in ~/.claude/settings.json so Claude Code
/// can forward approval requests to the CodeBubble app.
enum HookInstaller {
    private static let home = NSHomeDirectory()
    private static var claudeDir: String { home + "/.claude" }
    private static var hooksDir: String { claudeDir + "/hooks" }
    private static var bridgePath: String { hooksDir + "/codebubble-bridge" }
    private static var settingsPath: String { claudeDir + "/settings.json" }

    /// Install or refresh the bridge binary + hook entry. Idempotent.
    static func installIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)

        copyBridgeBinary(fm: fm)
        registerHook()
    }

    /// Remove our bridge + hook entry from settings.
    static func uninstall() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: bridgePath)

        guard let data = fm.contents(atPath: settingsPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        if var permissionReqs = hooks["PermissionRequest"] as? [[String: Any]] {
            permissionReqs.removeAll { entry in
                if let entryHooks = entry["hooks"] as? [[String: Any]] {
                    return entryHooks.contains { hook in
                        let cmd = hook["command"] as? String ?? ""
                        return cmd.contains("codebubble-bridge")
                    }
                }
                return false
            }
            if permissionReqs.isEmpty {
                hooks.removeValue(forKey: "PermissionRequest")
            } else {
                hooks["PermissionRequest"] = permissionReqs
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        writeJSON(json, to: settingsPath)
    }

    // MARK: - Bridge binary

    private static func copyBridgeBinary(fm: FileManager) {
        guard let srcPath = locateBridgeBinary(fm: fm) else {
            log.warning("Could not locate codebubble-bridge binary to install")
            return
        }

        // Copy (overwrite) and make executable
        try? fm.removeItem(atPath: bridgePath)
        do {
            try fm.copyItem(atPath: srcPath, toPath: bridgePath)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridgePath)
            log.info("Installed bridge binary to \(bridgePath)")
        } catch {
            log.error("Failed to install bridge: \(error.localizedDescription)")
        }
    }

    /// Find the bridge binary:
    /// 1. Contents/Helpers/codebubble-bridge (release .app bundle)
    /// 2. Same directory as the running executable (debug build)
    private static func locateBridgeBinary(fm: FileManager) -> String? {
        let mainPath = Bundle.main.executablePath ?? ""
        let mainDir = (mainPath as NSString).deletingLastPathComponent

        // .app bundle layout
        let helpersPath = (mainDir as NSString).deletingLastPathComponent + "/Helpers/codebubble-bridge"
        if fm.fileExists(atPath: helpersPath) { return helpersPath }

        // Debug build layout
        let sibling = mainDir + "/codebubble-bridge"
        if fm.fileExists(atPath: sibling) { return sibling }

        return nil
    }

    // MARK: - settings.json

    private static func registerHook() {
        let fm = FileManager.default

        var json: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = parsed
        }

        let hookCommand = bridgePath
        let hookDef: [String: Any] = [
            "type": "command",
            "command": hookCommand,
            "timeout": 86400
        ]
        let permissionEntry: [String: Any] = [
            "matcher": "*",
            "hooks": [hookDef]
        ]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        // Remove ALL legacy codebubble hook entries from every event
        // (old architecture registered hooks for 12+ events)
        for event in Array(hooks.keys) {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                if let entryHooks = entry["hooks"] as? [[String: Any]] {
                    return entryHooks.contains { hook in
                        let cmd = hook["command"] as? String ?? ""
                        return cmd.contains("codebubble")
                    }
                }
                return false
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        // Register our single PermissionRequest hook
        var permissionReqs = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        permissionReqs.append(permissionEntry)
        hooks["PermissionRequest"] = permissionReqs
        json["hooks"] = hooks

        writeJSON(json, to: settingsPath)
    }

    private static func writeJSON(_ json: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
