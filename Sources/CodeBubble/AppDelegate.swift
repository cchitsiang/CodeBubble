import AppKit
import ApplicationServices
import SwiftUI
import os.log

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.codebubble", category: "AppDelegate")

    var panelController: PanelWindowController?
    private var sessionMonitor: SessionMonitor?
    private var hookSocketServer: HookSocketServer?
    private var globalShortcutMonitor: Any?
    private var localShortcutMonitor: Any?
    private var wasAccessibilityGranted = false
    private var accessibilityTimer: Timer?
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("CodeBubble must stay running")
        ProcessInfo.processInfo.disableSuddenTermination()
        // Pre-set app icon so Dock/menu bar use the packaged bundle icon.
        NSApp.applicationIconImage = SettingsWindowController.bundleAppIcon()
        StatusItemController.shared.startObserving()

        // Start hook socket server (listens for PermissionRequest from Claude Code)
        hookSocketServer = HookSocketServer(appState: appState)
        hookSocketServer?.start()

        // Install/refresh hook in ~/.claude/settings.json + bridge binary
        HookInstaller.installIfNeeded()

        // Start passive session monitoring (JSONL/SQLite file polling)
        sessionMonitor = SessionMonitor(appState: appState)
        sessionMonitor?.start()
        appState.start()

        panelController = PanelWindowController(appState: appState)
        panelController?.showPanel()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reCheckAccessibility()
            }
        }

        #if DEBUG
        // Preview mode: inject mock data if --preview flag is present
        if let scenario = DebugHarness.requestedScenario() {
            Self.log.debug("Loading scenario: \(scenario.rawValue)")
            DebugHarness.apply(scenario, to: appState)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                if appState.surface == .collapsed {
                    withAnimation(NotchAnimation.pop) {
                        appState.surface = .sessionList
                    }
                }
            }
            return
        }
        #endif

        // Check for updates silently after a short delay
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            UpdateChecker.shared.checkForUpdates()
        }

        SoundManager.shared.playBoot()
        promptAccessibilityIfNeeded()
        setupGlobalShortcut()

        // Listen for Accessibility permission changes + poll as fallback
        if !wasAccessibilityGranted {
            // Instant: system broadcasts when Accessibility list changes
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.accessibility.api"),
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reCheckAccessibility() }
            }
            // Fallback: poll every 5s in case the notification doesn't fire
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reCheckAccessibility() }
            }
        }

        // Boot animation: brief expand to confirm app is running
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard appState.surface == .collapsed else { return }
            withAnimation(NotchAnimation.pop) {
                appState.surface = .sessionList
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if case .sessionList = appState.surface {
                withAnimation(NotchAnimation.close) {
                    appState.surface = .collapsed
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        teardownGlobalShortcut()
        sessionMonitor?.stop()
        hookSocketServer?.stop()
    }

    // MARK: - Global Shortcuts

    func setupGlobalShortcut() {
        teardownGlobalShortcut()

        // Collect all enabled shortcut bindings, skip duplicates (first wins)
        var bindings: [(keyCode: UInt16, mods: NSEvent.ModifierFlags, action: ShortcutAction)] = []
        var seen: Set<String> = []
        for action in ShortcutAction.allCases {
            guard action.isEnabled else { continue }
            let b = action.binding
            let key = "\(b.keyCode)-\(b.modifiers.rawValue)"
            guard seen.insert(key).inserted else { continue }
            bindings.append((b.keyCode, b.modifiers, action))
        }
        guard !bindings.isEmpty else { return }

        let handler: (NSEvent) -> Bool = { [weak self] event in
            let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            for b in bindings where event.keyCode == b.keyCode && eventMods == b.mods {
                Task { @MainActor in self?.executeShortcut(b.action) }
                return true
            }
            return false
        }

        globalShortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            _ = handler(event)
        }
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event) ? nil : event
        }
    }

    /// On first launch, prompt for Accessibility. After that, check silently.
    private func promptAccessibilityIfNeeded() {
        let key = "hasPromptedAccessibility"
        if !UserDefaults.standard.bool(forKey: key) {
            // First launch — show the system dialog once
            UserDefaults.standard.set(true, forKey: key)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            wasAccessibilityGranted = AXIsProcessTrustedWithOptions(options)
        } else {
            // Subsequent launches — check silently
            wasAccessibilityGranted = AXIsProcessTrusted()
        }
    }

    /// Called on app activation — if the user just granted Accessibility, re-register shortcuts.
    private func reCheckAccessibility() {
        guard !wasAccessibilityGranted else {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
            return
        }
        if AXIsProcessTrusted() {
            wasAccessibilityGranted = true
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
            setupGlobalShortcut()
        }
    }

    private func teardownGlobalShortcut() {
        if let m = globalShortcutMonitor { NSEvent.removeMonitor(m) }
        if let m = localShortcutMonitor { NSEvent.removeMonitor(m) }
        globalShortcutMonitor = nil
        localShortcutMonitor = nil
    }

    private func executeShortcut(_ action: ShortcutAction) {
        switch action {
        case .togglePanel:
            if appState.surface.isExpanded {
                withAnimation(NotchAnimation.close) { appState.surface = .collapsed }
            } else {
                withAnimation(NotchAnimation.open) {
                    if let q = appState.pendingHookQuestion {
                        appState.surface = .questionCard(sessionId: q.sessionId)
                        appState.activeSessionId = q.sessionId
                    } else if let a = appState.pendingHookApproval {
                        appState.surface = .approvalCard(sessionId: a.sessionId)
                        appState.activeSessionId = a.sessionId
                    } else if let pendingId = appState.pendingApprovalSessionId {
                        appState.surface = .approvalCard(sessionId: pendingId)
                        appState.activeSessionId = pendingId
                    } else {
                        appState.surface = .sessionList
                        appState.cancelCompletionQueue()
                        if appState.activeSessionId == nil {
                            appState.activeSessionId = appState.sessions.keys.sorted().first
                        }
                    }
                }
            }
        case .approve:
            // Only act when there's a hook-based approval pending
            guard appState.pendingHookApproval != nil else { break }
            appState.approveHookApproval(always: false)
        case .approveAlways:
            guard appState.pendingHookApproval != nil else { break }
            appState.approveHookApproval(always: true)
        case .deny:
            guard appState.pendingHookApproval != nil else { break }
            appState.denyHookApproval()
        case .skipQuestion:
            // Not applicable — question UI removed
            break
        case .jumpToTerminal:
            if let id = appState.activeSessionId, let session = appState.sessions[id] {
                TerminalActivator.activate(session: session, sessionId: id)
            }
        }
    }

}
