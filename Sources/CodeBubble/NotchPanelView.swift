import SwiftUI
import CodeBubbleCore

struct NotchPanelView: View {
    var appState: AppState
    let hasNotch: Bool
    let notchHeight: CGFloat
    let notchW: CGFloat
    let screenWidth: CGFloat

    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    @AppStorage(SettingsKey.showAgentDetails) private var showAgentDetails = SettingsDefaults.showAgentDetails
    @AppStorage(SettingsKey.smartSuppress) private var smartSuppress = SettingsDefaults.smartSuppress
    @AppStorage(SettingsKey.hideWhenNoSession) private var hideWhenNoSession = SettingsDefaults.hideWhenNoSession
    @AppStorage(SettingsKey.showToolStatus) private var showToolStatus = SettingsDefaults.showToolStatus
    @AppStorage(SettingsKey.collapsedWidthScale) private var collapsedWidthScale = SettingsDefaults.collapsedWidthScale

    /// Delayed hover: prevents accidental expansion when mouse passes through
    @State private var hoverTimer: Timer?
    @State private var isHovered = false
    @State private var idleHovered = false
    /// Curtain animation for tool status toggle
    @State private var curtainOffset: CGFloat = 0
    @State private var curtainOpacity: Double = 1
    @State private var displayedToolStatus: Bool = SettingsDefaults.showToolStatus

    private var isActive: Bool { !appState.sessions.isEmpty }
    /// First launch / no-session state should still render a visible marker so the app
    /// doesn't disappear completely behind the physical notch.
    private var showIdleIndicator: Bool {
        !isActive && !hideWhenNoSession
    }
    /// Whether the bar content should be visible (respects hideWhenNoSession)
    private var showBar: Bool {
        isActive && !(hideWhenNoSession && appState.activeSessionCount == 0)
    }
    private var shouldShowExpanded: Bool {
        showBar && appState.surface.isExpanded
    }

    /// Mascot size — fits within the menu bar height
    private var mascotSize: CGFloat { min(27, notchHeight - 6) }

    /// Minimum wing width needed to display compact bar content
    private var compactWingWidth: CGFloat { mascotSize + 14 }

    /// Effective notch width — applies user scale on non-notch screens (#56).
    private var effectiveNotchW: CGFloat {
        guard !hasNotch else { return notchW }
        let scale = CGFloat(max(collapsedWidthScale, 50)) / 100.0
        return notchW * scale
    }

    /// Total panel width — adapts based on state and screen geometry
    private var panelWidth: CGFloat {
        let nw = effectiveNotchW
        let maxWidth = min(620, screenWidth - 40)
        if showIdleIndicator { return idleHovered ? nw + compactWingWidth * 2 + 80 : nw + compactWingWidth * 2 }
        if !isActive { return hasNotch ? notchW - 20 : nw }
        if shouldShowExpanded { return min(max(nw + 200, 580), maxWidth) }
        let wing = compactWingWidth
        let extra: CGFloat = appState.status == .idle ? 0 : 20
        // Reserve space for tool status — proportional to screen width
        let toolExtra: CGFloat = displayedToolStatus ? (hasNotch ? screenWidth * 0.03 : screenWidth * 0.04) : 0
        return nw + wing * 2 + extra + toolExtra
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if showBar {
                    // Active: compact bar — wider version when expanded
                    HStack(spacing: 0) {
                        CompactLeftWing(appState: appState, expanded: shouldShowExpanded, mascotSize: mascotSize, hasNotch: hasNotch, showToolStatus: showToolStatus)
                        if hasNotch && !shouldShowExpanded {
                            Spacer(minLength: notchW)
                        } else if !shouldShowExpanded && showToolStatus {
                            CompactToolStatus(appState: appState)
                            Spacer(minLength: 0)
                        } else {
                            Spacer(minLength: 0)
                        }
                        CompactRightWing(appState: appState, expanded: shouldShowExpanded, hasNotch: hasNotch)
                    }
                    .frame(height: notchHeight)
                } else if showIdleIndicator {
                    IdleIndicatorBar(
                        mascotSize: mascotSize,
                        compactWingWidth: compactWingWidth,
                        notchW: notchW,
                        notchHeight: notchHeight,
                        hasNotch: hasNotch,
                        hovered: idleHovered
                    )
                } else {
                    // Idle: just the notch shell
                    Spacer()
                        .frame(height: notchHeight)
                }

                // Below-notch expanded content
                if shouldShowExpanded {
                    Line()
                        .stroke(.white.opacity(0.15), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                        .frame(height: 0.5)
                        .padding(.horizontal, 12)

                    switch appState.surface {
                    case .approvalCard(let sessionId):
                        if let session = appState.sessions[sessionId] {
                            VStack(spacing: 0) {
                                ApprovalBar(
                                    tool: session.pendingApprovalTool ?? session.currentTool ?? "Tool",
                                    detail: session.pendingApprovalDetail,
                                    sessionSource: session.source,
                                    projectName: session.projectDisplayName,
                                    queueCount: appState.hookApprovalQueue.count,
                                    isInteractive: appState.pendingHookApproval?.sessionId == sessionId,
                                    onJumpToTerminal: {
                                        TerminalActivator.activate(session: session, sessionId: sessionId)
                                    },
                                    onAllow: { appState.approveHookApproval(always: false) },
                                    onAllowAlways: { appState.approveHookApproval(always: true) },
                                    onDeny: { appState.denyHookApproval() }
                                )
                                if appState.sessions.count > 1 {
                                    SessionsExpandLink(count: appState.sessions.count) {
                                        withAnimation(NotchAnimation.open) {
                                            appState.surface = .sessionList
                                        }
                                    }
                                }
                            }
                            .transition(.blurFade.combined(with: .move(edge: .top)))
                        }
                    case .questionCard(let sessionId):
                        if let q = appState.pendingHookQuestion, q.sessionId == sessionId {
                            VStack(spacing: 0) {
                                QuestionBar(
                                    items: q.items,
                                    sessionSource: appState.sessions[sessionId]?.source,
                                    projectName: appState.sessions[sessionId]?.projectDisplayName,
                                    onAnswer: { appState.answerHookQuestion($0) },
                                    onSkip: { appState.skipHookQuestion() }
                                )
                                if appState.sessions.count > 1 {
                                    SessionsExpandLink(count: appState.sessions.count) {
                                        withAnimation(NotchAnimation.open) {
                                            appState.surface = .sessionList
                                        }
                                    }
                                }
                            }
                            .transition(.blurFade.combined(with: .move(edge: .top)))
                        }
                    case .completionCard:
                        SessionListView(appState: appState, onlySessionId: appState.justCompletedSessionId)
                            .transition(.blurFade.combined(with: .move(edge: .top)))
                    case .sessionList:
                        SessionListView(appState: appState, onlySessionId: nil)
                            .transition(.blurFade.combined(with: .move(edge: .top)))
                    case .collapsed:
                        EmptyView()
                    }
                }
            }
            .frame(width: panelWidth)
            .clipped()
            .background(
                NotchPanelShape(
                    topExtension: shouldShowExpanded ? 14 : 3,
                    bottomRadius: shouldShowExpanded ? 24 : 12,
                    minHeight: notchHeight
                )
                .fill(.black)
            )
            .offset(y: curtainOffset)
            .opacity(curtainOpacity)
            .onChange(of: showToolStatus) { _, newValue in
                // Phase 1: entire bar slides up and fades out
                withAnimation(.easeIn(duration: 0.2)) {
                    curtainOffset = -notchHeight
                    curtainOpacity = 0
                }
                // Phase 2: switch width while hidden
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    displayedToolStatus = newValue
                }
                // Phase 3: entire bar slides back down
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        curtainOffset = 0
                        curtainOpacity = 1
                    }
                }
            }
            .onAppear { displayedToolStatus = showToolStatus }
            .contentShape(Rectangle())
            .onHover { hovering in
                // Idle indicator hover — delay un-hover to prevent oscillation when
                // the animated width change crosses the mouse position (#52).
                if showIdleIndicator {
                    if hovering {
                        hoverTimer?.invalidate()
                        hoverTimer = nil
                        withAnimation(NotchAnimation.micro) { idleHovered = true }
                    } else {
                        hoverTimer?.invalidate()
                        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                            Task { @MainActor in
                                withAnimation(NotchAnimation.micro) { idleHovered = false }
                            }
                        }
                    }
                    return
                }
                switch appState.surface {
                case .completionCard:
                    // Completion card: mark entered on hover-in, block collapse until entered
                    if hovering {
                        appState.completionHasBeenEntered = true
                    } else if appState.completionHasBeenEntered {
                        // Mouse entered then left — allow collapse
                        hoverTimer?.invalidate()
                        hoverTimer = nil
                        withAnimation(NotchAnimation.close) {
                            appState.surface = .collapsed
                            appState.cancelCompletionQueue()
                        }
                    }
                    return
                default: break
                }
                // Respect collapseOnMouseLeave setting
                if !hovering && !SettingsManager.shared.collapseOnMouseLeave { return }
                // Smart suppress: don't auto-expand when active session's terminal is foreground
                if hovering && smartSuppress {
                    if let delegate = NSApp.delegate as? AppDelegate,
                       let pc = delegate.panelController,
                       pc.isActiveTerminalForeground() {
                        return
                    }
                }

                isHovered = hovering
                if hovering {
                    // Delay expansion to avoid accidental triggers
                    hoverTimer?.invalidate()
                    hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                        Task { @MainActor in
                            // Guard: mouse may have left during the delay
                            guard isHovered else { return }
                            withAnimation(NotchAnimation.open) {
                                // Prefer hook-based items, then JSONL-detected pending approvals
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
                    }
                } else {
                    // Collapse with brief delay to prevent flicker on accidental mouse-out
                    hoverTimer?.invalidate()
                    hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
                        Task { @MainActor in
                            guard !isHovered else { return }
                            withAnimation(NotchAnimation.close) {
                                appState.surface = .collapsed
                            }
                        }
                    }
                }
            }

            Spacer()
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(NotchAnimation.open, value: appState.surface)
    }
}


// MARK: - Compact Wings (notch-level, 32px height)

/// Left side: pixel character + status info
private struct CompactLeftWing: View {
    var appState: AppState
    let expanded: Bool
    let mascotSize: CGFloat
    let hasNotch: Bool
    let showToolStatus: Bool
    @AppStorage(SettingsKey.sessionGroupingMode) private var groupingMode = SettingsDefaults.sessionGroupingMode
    private var displaySession: SessionSnapshot? {
        let sid = appState.rotatingSessionId ?? appState.activeSessionId ?? appState.sessions.keys.sorted().first
        guard let sid else { return nil }
        return appState.sessions[sid]
    }
    private var displaySource: String { displaySession?.source ?? appState.primarySource }
    private var displayStatus: AgentStatus { displaySession?.status ?? .idle }
    private var liveTool: String? { displaySession?.currentTool }
    @State private var shownTool: String?
    @State private var lingerTimer: Timer?

    var body: some View {
        HStack(spacing: 6) {
            if expanded {
                AppLogoView(size: 18, showBackground: false)
                    .padding(.leading, 4)
                if appState.sessions.count > 1 {
                    HStack(spacing: 1) {
                        ForEach([("status", "STATUS"), ("newest", "NEWEST")], id: \.0) { tag, label in
                            let selected = groupingMode == tag
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { groupingMode = tag }
                            } label: {
                                PixelText(
                                    text: label,
                                    color: selected ? Color(red: 0.3, green: 0.85, blue: 0.4) : .white.opacity(0.3),
                                    pixelSize: 1.3
                                )
                                .padding(.horizontal, 5)
                                .padding(.vertical, 4)
                                .background(
                                    Rectangle().fill(selected ? .white.opacity(0.1) : .clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Rectangle().fill(.white.opacity(0.05)))
                    .overlay(Rectangle().stroke(.white.opacity(0.1), lineWidth: 1))
                }
            } else {
                MascotView(source: displaySource, status: displayStatus, size: mascotSize)
                    .id(displaySource)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: displaySource)

                // On notch screens, show tool name only (no description, space is tight)
                if hasNotch, showToolStatus, let tool = shownTool {
                    Text(tool)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(toolStatusColor(tool))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
        }
        .padding(.leading, 6)
        .clipped()
        .onChange(of: liveTool) { _, newTool in
            lingerTimer?.invalidate()
            if let newTool {
                withAnimation(.easeInOut(duration: 0.2)) { shownTool = newTool }
            } else {
                lingerTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.3)) { shownTool = nil }
                    }
                }
            }
        }
        // Session rotation: immediately sync tool to avoid stale linger from previous session
        .onChange(of: appState.rotatingSessionId) { _, _ in
            lingerTimer?.invalidate()
            let newTool = liveTool
            withAnimation(.easeInOut(duration: 0.2)) { shownTool = newTool }
        }
    }
}

/// Right side: project name + session count (detailed) or just count (simple)
private struct CompactRightWing: View {
    var appState: AppState
    let expanded: Bool
    let hasNotch: Bool
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.soundEnabled) private var soundEnabled = SettingsDefaults.soundEnabled
    @AppStorage(SettingsKey.showToolStatus) private var showToolStatus = SettingsDefaults.showToolStatus

    private var displaySessionId: String? {
        appState.rotatingSessionId ?? appState.activeSessionId ?? appState.sessions.keys.sorted().first
    }
    private var projectName: String? {
        guard let sid = displaySessionId, let cwd = appState.sessions[sid]?.cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 6) {
            if expanded {
                NotchIconButton(icon: soundEnabled ? "speaker.wave.2" : "speaker.slash", tooltip: soundEnabled ? l10n["mute"] : l10n["enable_sound_tooltip"]) {
                    soundEnabled.toggle()
                }
                NotchIconButton(icon: "gearshape", tooltip: l10n["settings"]) {
                    SettingsWindowController.shared.show()
                }
                NotchIconButton(icon: "power", tint: Color(red: 1.0, green: 0.4, blue: 0.4), tooltip: l10n["quit"]) {
                    NSApplication.shared.terminate(nil)
                }
            } else {
                // Waiting for user badge
                if appState.status == .waitingForUser {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.7, blue: 0.28))
                        .symbolEffect(.pulse, options: .repeating)
                }

                if showToolStatus {
                    // Detailed mode: session count (project name is shown in center on non-notch)
                    HStack(spacing: 1) {
                        let active = appState.activeSessionCount
                        let total = appState.totalSessionCount
                        if active > 0 {
                            Text("\(active)")
                                .foregroundStyle(Color(red: 0.4, green: 1.0, blue: 0.5))
                            Text("/")
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Text("\(total)")
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                } else {
                    // Simple mode: original session count only
                    HStack(spacing: 1) {
                        let active = appState.activeSessionCount
                        let total = appState.totalSessionCount
                        if active > 0 {
                            Text("\(active)")
                                .foregroundStyle(Color(red: 0.4, green: 1.0, blue: 0.5))
                            Text("/")
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Text("\(total)")
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
        }
        .padding(.trailing, 6)
    }
}

// MARK: - Tool Status Helpers

/// Accent color for each tool category — shared between notch and non-notch views
private func toolStatusColor(_ tool: String) -> Color {
    switch tool.lowercased() {
    case "bash": return Color(red: 0.4, green: 1.0, blue: 0.5)
    case "edit", "write": return Color(red: 0.5, green: 0.7, blue: 1.0)
    case "read": return Color(red: 0.9, green: 0.8, blue: 0.4)
    case "grep", "glob": return Color(red: 0.8, green: 0.6, blue: 1.0)
    case "agent": return Color(red: 1.0, green: 0.6, blue: 0.4)
    default: return .white.opacity(0.7)
    }
}

// MARK: - Compact Tool Status (non-notch center area)

/// Shows the current tool activity in the center of the bar on non-notch screens.
/// Keeps the last tool visible for a short linger period to avoid flashing.
private struct CompactToolStatus: View {
    var appState: AppState

    /// Single source of truth: all fields derive from the same session.
    private var displaySessionId: String? {
        appState.rotatingSessionId ?? appState.activeSessionId ?? appState.sessions.keys.sorted().first
    }
    private var displaySession: SessionSnapshot? {
        guard let sid = displaySessionId else { return nil }
        return appState.sessions[sid]
    }
    private var liveTool: String? { displaySession?.currentTool }
    private var liveDesc: String? { displaySession?.toolDescription }
    private var displayStatus: AgentStatus { displaySession?.status ?? .idle }
    private var projectName: String? {
        guard let cwd = displaySession?.cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    @State private var shownTool: String?
    @State private var shownDesc: String?
    @State private var lingerTimer: Timer?

    /// Extract meaningful part of description — file paths show last component
    private func shortDesc(_ desc: String) -> String {
        let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") {
            return (trimmed as NSString).lastPathComponent
        }
        return trimmed
    }

    /// Whether the current session is doing any work (not idle)
    private var isWorking: Bool { displayStatus != .idle }

    var body: some View {
        HStack(spacing: 5) {
            // Project name — shown whenever the session is not idle
            if isWorking, let project = projectName {
                Text(project)
                    .foregroundStyle(.white.opacity(0.8))
                    .id("center-project-\(displaySessionId ?? "")")
                    .transition(.opacity)
            }

            // Tool status or thinking indicator
            if let tool = shownTool {
                TypingIndicator(fontSize: 11, label: tool, bright: true, color: toolStatusColor(tool))
                    .id("tool-\(tool)-\(appState.rotatingSessionId ?? "")")
                if let desc = shownDesc {
                    MorphText(
                        text: shortDesc(desc),
                        font: .system(size: 11, weight: .medium, design: .monospaced),
                        color: .white.opacity(0.7)
                    )
                    .truncationMode(.tail)
                }
            } else if displayStatus == .thinking {
                TypingIndicator(fontSize: 11, label: "thinking", bright: true)
                    .id("thinking-\(appState.rotatingSessionId ?? "")")
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .padding(.leading, 6)
        .animation(.easeInOut(duration: 0.25), value: shownTool)
        .animation(.easeInOut(duration: 0.15), value: shownDesc)
        .animation(.easeInOut(duration: 0.3), value: appState.rotatingSessionId)
        .onChange(of: liveTool) { _, newTool in
            lingerTimer?.invalidate()
            if let newTool {
                shownTool = newTool
                shownDesc = liveDesc
            } else {
                lingerTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.3)) {
                            shownTool = nil
                            shownDesc = nil
                        }
                    }
                }
            }
        }
        .onChange(of: liveDesc) { _, newDesc in
            if liveTool != nil { shownDesc = newDesc }
        }
        // Session rotation: immediately sync to avoid stale linger from previous session
        .onChange(of: appState.rotatingSessionId) { _, _ in
            lingerTimer?.invalidate()
            withAnimation(.easeInOut(duration: 0.2)) {
                shownTool = liveTool
                shownDesc = liveDesc
            }
        }
    }
}

private struct NotchIconButton: View {
    let icon: String
    var tint: Color = .white
    var tooltip: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint.opacity(hovering ? 1.0 : 0.85))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(tint.opacity(hovering ? 0.2 : 0.08))
                )
                .scaleEffect(hovering ? 1.1 : 1.0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(NotchAnimation.micro) { hovering = h } }
        .help(tooltip ?? "")
    }
}

// MARK: - Idle Indicator Bar

private struct IdleIndicatorBar: View {
    let mascotSize: CGFloat
    let compactWingWidth: CGFloat
    let notchW: CGFloat
    let notchHeight: CGFloat
    let hasNotch: Bool
    let hovered: Bool
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.soundEnabled) private var soundEnabled = SettingsDefaults.soundEnabled

    var body: some View {
        HStack(spacing: 0) {
            // Left: mascot
            HStack(spacing: 6) {
                MascotView(source: "claude", status: .idle, size: mascotSize)
                    .opacity(hovered ? 0.9 : 0.5)
            }
            .padding(.leading, 6)

            Spacer(minLength: hasNotch ? notchW : 0)

            // Right: expanded shows text + buttons, collapsed shows nothing
            if hovered {
                HStack(spacing: 8) {
                    Text("0")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))

                    HStack(spacing: 4) {
                        NotchIconButton(icon: soundEnabled ? "speaker.wave.2" : "speaker.slash", tooltip: soundEnabled ? l10n["mute"] : l10n["enable_sound_tooltip"]) {
                            soundEnabled.toggle()
                        }
                        NotchIconButton(icon: "gearshape", tooltip: l10n["settings"]) {
                            SettingsWindowController.shared.show()
                        }
                        NotchIconButton(icon: "power", tint: Color(red: 1.0, green: 0.4, blue: 0.4), tooltip: l10n["quit"]) {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                }
                .padding(.trailing, 6)
                .transition(.opacity)
            }
        }
        .frame(height: notchHeight)
        .animation(NotchAnimation.micro, value: hovered)
    }
}


// MARK: - Session List

private struct SessionListView: View {
    var appState: AppState
    /// When set, only show this session (auto-expand on completion)
    var onlySessionId: String? = nil
    @AppStorage(SettingsKey.sessionGroupingMode) private var groupingMode = SettingsDefaults.sessionGroupingMode
    @AppStorage(SettingsKey.maxVisibleSessions) private var maxVisibleSessions = SettingsDefaults.maxVisibleSessions

    private var groupedSessions: [(header: String, source: String?, ids: [String])] {
        if let only = onlySessionId, appState.sessions[only] != nil {
            return [("", nil, [only])]
        }

        switch groupingMode {
        case "status":
            // Group by status, active sessions first
            let l10n = L10n.shared
            let groups: [(Set<AgentStatus>, String)] = [
                ([.waitingForUser], l10n["status_waiting"]),
                ([.running, .thinking], l10n["status_processing"]),
                ([.idle], l10n["status_idle"]),
            ]
            let allIds = appState.sessions.keys.sorted { a, b in
                appState.sessions[a]!.lastActivity > appState.sessions[b]!.lastActivity
            }
            var result: [(String, String?, [String])] = []
            for (statuses, label) in groups {
                let ids = allIds.filter { id in
                    guard let s = appState.sessions[id] else { return false }
                    return statuses.contains(s.status)
                }
                if !ids.isEmpty {
                    result.append(("\(label) (\(ids.count))", nil, ids))
                }
            }
            return result

        default: // "newest" — flat list sorted by most recent activity
            let sorted = appState.sessions.keys.sorted { a, b in
                appState.sessions[a]!.lastActivity > appState.sessions[b]!.lastActivity
            }
            return [("", nil, sorted)]
        }
    }

    var body: some View {
        // Compute once per render — groupedSessions, totalCount, needsScroll
        let groups = groupedSessions
        let totalSessionCount = groups.reduce(0) { $0 + $1.ids.count }
        let needsScroll = onlySessionId == nil && totalSessionCount > maxVisibleSessions
        let content = VStack(spacing: 6) {
            ForEach(groups, id: \.header) { group in
                if !group.header.isEmpty {
                    HStack(spacing: 6) {
                        if let src = group.source, let icon = cliIcon(source: src) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 14, height: 14)
                        }
                        Text(group.header)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                }

                ForEach(group.ids, id: \.self) { sessionId in
                    if let session = appState.sessions[sessionId] {
                        SessionCard(
                            appState: appState,
                            sessionId: sessionId,
                            session: session,
                            isCompletion: onlySessionId != nil
                        )
                    }
                }
            }

            // "Show all sessions" — hover with delay to expand
            if onlySessionId != nil && appState.sessions.count > 1 {
                SessionsExpandLink(count: appState.sessions.count) {
                    withAnimation(NotchAnimation.open) {
                        appState.surface = .sessionList
                        appState.cancelCompletionQueue()
                    }
                }
            }
        }
        .padding(.vertical, 4)

        if needsScroll {
            ThinScrollView(maxHeight: CGFloat(maxVisibleSessions) * 90) {
                content
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: 20,
                    bottomTrailingRadius: 20, topTrailingRadius: 0,
                    style: .continuous
                )
            )
        } else {
            content
        }
    }
}

/// Thin overlay scrollbar via NSScrollView — ignores system "show scrollbar" preference.
private struct ThinScrollView<Content: View>: NSViewRepresentable {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.controlSize = .mini
        scrollView.drawsBackground = false
        scrollView.scrollerKnobStyle = .light

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: maxHeight),
        ])

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let hosting = scrollView.documentView as? NSHostingView<Content> {
            hosting.rootView = content
        }
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.controlSize = .mini
    }
}

private struct SessionIdentityLine: View {
    let session: SessionSnapshot
    let sessionId: String
    let projectFontSize: CGFloat
    let projectColor: Color
    let sessionFontSize: CGFloat
    let sessionColor: Color
    let dividerColor: Color

    var body: some View {
        HStack(spacing: 4) {
            ProjectNameLink(
                name: session.projectDisplayName ?? "Unknown",
                cwd: session.cwd,
                isInteractive: true,
                fontSize: projectFontSize,
                color: projectColor
            )
            .layoutPriority(2)

            Text("#\(shortSessionId(sessionId))")
                .font(.system(size: sessionFontSize, weight: .medium, design: .monospaced))
                .foregroundStyle(sessionColor.opacity(0.6))
                .fixedSize()
        }
    }
}

private struct ProjectNameLink: View {
    let name: String
    let cwd: String?
    let isInteractive: Bool
    let fontSize: CGFloat
    let color: Color

    var body: some View {
        Text(name)
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .onTapGesture {
                if isInteractive, let cwd = cwd {
                    NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
                }
            }
            .help(isInteractive && cwd != nil ? "\(L10n.shared["open_path"]) \(cwd!)" : "")
    }
}

private struct SessionsExpandLink: View {
    let count: Int
    let action: () -> Void
    @State private var hovering = false
    @State private var hoverTimer: Timer?

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
                Text("\(count) \(L10n.shared["n_sessions"])")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(hovering ? 0.7 : 0.45))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(hovering ? 0.5 : 0.3))
                Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(NotchAnimation.micro) { hovering = h }
            hoverTimer?.invalidate()
            hoverTimer = nil
            if h {
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
                    Task { @MainActor in action() }
                }
            }
        }
    }
}

private struct SessionCard: View {
    var appState: AppState
    let sessionId: String
    let session: SessionSnapshot
    var isCompletion: Bool = false
    @State private var hovering = false
    @State private var expanded = false
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    @AppStorage(SettingsKey.aiMessageLines) private var aiMessageLines = SettingsDefaults.aiMessageLines
    @AppStorage(SettingsKey.showAgentDetails) private var showAgentDetails = SettingsDefaults.showAgentDetails
    private var fontSize: CGFloat { CGFloat(contentFontSize) }
    private var aiLineLimit: Int? { aiMessageLines > 0 ? aiMessageLines : nil }
    private var statusNameColor: Color {
        switch session.status {
        case .thinking, .running:    return Color(red: 0.3, green: 0.85, blue: 0.4)
        case .waitingForUser:        return Color(red: 1.0, green: 0.6, blue: 0.2)
        case .idle:                  return .white
        }
    }

    /// True if this session has a pending approval (either hook-based or JSONL-detected).
    private var hasPendingApproval: Bool {
        if appState.pendingHookApproval?.sessionId == sessionId { return true }
        // Passive fallback only when hooks aren't installed
        if !HookInstaller.isInstalled(),
           session.status == .waitingForUser, session.pendingApprovalTool != nil { return true }
        return false
    }

    /// True if this session has a pending question via hook.
    private var hasPendingQuestion: Bool {
        appState.pendingHookQuestion?.sessionId == sessionId
    }

    var body: some View {
        Button {
            if hasPendingQuestion {
                withAnimation(NotchAnimation.open) {
                    appState.surface = .questionCard(sessionId: sessionId)
                    appState.activeSessionId = sessionId
                }
            } else if hasPendingApproval {
                withAnimation(NotchAnimation.open) {
                    appState.surface = .approvalCard(sessionId: sessionId)
                    appState.activeSessionId = sessionId
                }
            } else {
                // Toggle inline expansion to show last assistant message
                withAnimation(NotchAnimation.micro) { expanded.toggle() }
            }
        } label: {
        HStack(alignment: .center, spacing: 8) {
            // Column 1: Character
            VStack(spacing: 3) {
                MascotView(source: session.source, status: session.status, size: 32)
            }
            .frame(width: 36)

            // Column 2: Content
            VStack(alignment: .leading, spacing: 6) {
                // Header: project name + short ID
                HStack(alignment: .center, spacing: 8) {
                    SessionIdentityLine(
                        session: session,
                        sessionId: sessionId,
                        projectFontSize: fontSize + 2,
                        projectColor: statusNameColor,
                        sessionFontSize: fontSize,
                        sessionColor: .white.opacity(0.76),
                        dividerColor: .white.opacity(0.28)
                    )
                    Spacer(minLength: 8)

                    HStack(spacing: 4) {
                        SessionTag(timeAgo(session.startTime))
                        TerminalBadge(session: session)
                        Button {
                            TerminalActivator.activate(session: session, sessionId: sessionId)
                        } label: {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Jump to terminal")
                    }
                }

                // Session title: first user prompt
                if let prompt = session.lastUserPrompt {
                    Text(prompt)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // Working indicator: show what AI is doing right now
                if session.status != .idle {
                    HStack(spacing: 4) {
                        Text("$")
                            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                        if let tool = session.currentTool {
                            MorphText(
                                text: session.toolDescription ?? tool,
                                font: .system(size: fontSize, design: .monospaced),
                                color: .white.opacity(0.75)
                            )
                            .truncationMode(.tail)
                        } else {
                            TypingIndicator(fontSize: fontSize, label: "thinking")
                        }
                    }
                    .padding(.leading, 4)
                }

                // Last assistant message: shown on completion card or when card is tapped
                if (isCompletion || expanded),
                   let reply = session.lastAssistantMessage, !reply.isEmpty {
                    Text(reply)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(expanded ? 8 : 4)
                        .truncationMode(.tail)
                        .padding(.top, 2)
                }
            } // end Column 2 VStack
        } // end HStack
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hovering ? Color.white.opacity(0.10) : Color.white.opacity(0.05))
        )
        .padding(.horizontal, 6)
        } // end Button label
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(NotchAnimation.micro) { hovering = h } }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "<1m" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

// MARK: - Claude Logo (official sunburst from simple-icons, viewBox 0 0 24 24)

private struct ClaudeLogo: View {
    var size: CGFloat = 22
    private static let color = Color(red: 0.85, green: 0.47, blue: 0.34) // #D97757

    // Official Claude logo SVG path (source: simple-icons)
    fileprivate static let svgPath = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"

    var body: some View {
        ClaudeLogoShape()
            .fill(Self.color)
            .frame(width: size, height: size)
    }
}

private struct ClaudeLogoShape: Shape {
    private static let basePath: Path = ClaudeLogoShape.parseSVGPath(ClaudeLogo.svgPath)

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24.0
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return Self.basePath.applying(transform)
    }

    // Minimal SVG path parser for m/l/h/v/c/z commands
    private static func parseSVGPath(_ d: String) -> Path {
        var path = Path()
        var x: CGFloat = 0, y: CGFloat = 0
        var i = d.startIndex
        var cmd: Character = "m"

        func skipWS() {
            while i < d.endIndex && (d[i] == " " || d[i] == ",") { i = d.index(after: i) }
        }

        func peekNum() -> Bool {
            guard i < d.endIndex else { return false }
            let c = d[i]
            return c == "-" || c == "." || c.isNumber
        }

        func num() -> CGFloat {
            skipWS()
            var s = ""
            if i < d.endIndex && d[i] == "-" { s.append(d[i]); i = d.index(after: i) }
            var hasDot = false
            while i < d.endIndex {
                let c = d[i]
                if c == "." {
                    if hasDot { break }
                    hasDot = true; s.append(c); i = d.index(after: i)
                } else if c.isNumber {
                    s.append(c); i = d.index(after: i)
                } else { break }
            }
            return CGFloat(Double(s) ?? 0)
        }

        while i < d.endIndex {
            skipWS()
            guard i < d.endIndex else { break }
            let c = d[i]
            if c.isLetter {
                cmd = c; i = d.index(after: i)
            }

            switch cmd {
            case "m":
                let dx = num(), dy = num(); x += dx; y += dy
                path.move(to: CGPoint(x: x, y: y))
                cmd = "l" // subsequent coords are implicit lineTo
            case "M":
                x = num(); y = num()
                path.move(to: CGPoint(x: x, y: y))
                cmd = "L"
            case "l":
                let dx = num(), dy = num(); x += dx; y += dy
                path.addLine(to: CGPoint(x: x, y: y))
            case "L":
                x = num(); y = num()
                path.addLine(to: CGPoint(x: x, y: y))
            case "h":
                x += num(); path.addLine(to: CGPoint(x: x, y: y))
            case "H":
                x = num(); path.addLine(to: CGPoint(x: x, y: y))
            case "v":
                y += num(); path.addLine(to: CGPoint(x: x, y: y))
            case "V":
                y = num(); path.addLine(to: CGPoint(x: x, y: y))
            case "c":
                let dx1 = num(), dy1 = num(), dx2 = num(), dy2 = num(), dx = num(), dy = num()
                path.addCurve(to: CGPoint(x: x+dx, y: y+dy),
                              control1: CGPoint(x: x+dx1, y: y+dy1),
                              control2: CGPoint(x: x+dx2, y: y+dy2))
                x += dx; y += dy
            case "C":
                let x1 = num(), y1 = num(), x2 = num(), y2 = num()
                x = num(); y = num()
                path.addCurve(to: CGPoint(x: x, y: y),
                              control1: CGPoint(x: x1, y: y1),
                              control2: CGPoint(x: x2, y: y2))
            case "Z", "z":
                path.closeSubpath()
            default:
                i = d.index(after: i)
            }

            // Handle repeated implicit commands
            skipWS()
            if i < d.endIndex && peekNum() && "mlhvcMLHVC".contains(cmd) {
                continue
            }
        }
        return path
    }
}

// MARK: - Notch Panel Shape (inverse radius at top, regular radius at bottom)

private struct NotchPanelShape: Shape {
    var topExtension: CGFloat
    var bottomRadius: CGFloat
    /// Fixed minimum height — NOT animated, prevents spring overshoot from exposing the notch
    var minHeight: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topExtension, bottomRadius) }
        set {
            topExtension = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let ext = topExtension
        let maxY = max(rect.maxY, rect.minY + minHeight)
        let br = min(bottomRadius, rect.width / 4, (maxY - rect.minY) / 2)
        // Smoothness factor for continuous-curvature corners (superellipse approximation).
        // 0.5523 = perfect circle; higher values tighten the curve for an Apple squircle feel.
        let k: CGFloat = 0.62

        var p = Path()
        // Top edge (extends into notch area via wings)
        p.move(to: CGPoint(x: rect.minX - ext, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX + ext, y: rect.minY))
        // Right shoulder: cubic bezier tangent to top line (horizontal) and right side (vertical)
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + ext),
            control1: CGPoint(x: rect.maxX + ext * 0.35, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + ext * 0.35)
        )
        // Right side down to bottom-right corner
        p.addLine(to: CGPoint(x: rect.maxX, y: maxY - br))
        // Bottom-right: cubic bezier for continuous-curvature corner
        p.addCurve(
            to: CGPoint(x: rect.maxX - br, y: maxY),
            control1: CGPoint(x: rect.maxX, y: maxY - br * (1 - k)),
            control2: CGPoint(x: rect.maxX - br * (1 - k), y: maxY)
        )
        // Bottom edge
        p.addLine(to: CGPoint(x: rect.minX + br, y: maxY))
        // Bottom-left: cubic bezier for continuous-curvature corner
        p.addCurve(
            to: CGPoint(x: rect.minX, y: maxY - br),
            control1: CGPoint(x: rect.minX + br * (1 - k), y: maxY),
            control2: CGPoint(x: rect.minX, y: maxY - br * (1 - k))
        )
        // Left side up to shoulder
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + ext))
        // Left shoulder: cubic bezier tangent to left side (vertical) and top line (horizontal)
        p.addCurve(
            to: CGPoint(x: rect.minX - ext, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + ext * 0.35),
            control2: CGPoint(x: rect.minX - ext * 0.35, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}

/// Source badge (display only, not a button)
private struct TerminalBadge: View {
    let session: SessionSnapshot

    private static let sourceBundleIds: [String: String] = [
        "cursor": "com.todesktop.230313mzl4w4u92",
        "codex": "com.openai.codex",
        "opencode": "ai.opencode.desktop",
    ]
    private static var termIconCache: [String: NSImage] = [:]

    private var termIcon: NSImage? {
        let bid = Self.sourceBundleIds[session.source]
        guard let bid else { return nil }
        if let cached = Self.termIconCache[bid] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Self.termIconCache[bid] = icon
        return icon
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon = termIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 13, height: 13)
            }
            Text(session.source)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// Collapsed single-line row for idle sessions >15 min
// MARK: - Pixel Text (5×7 dot matrix style)

private struct PixelText: View {
    let text: String
    let color: Color
    var pixelSize: CGFloat = 2

    private static let W = 5  // glyph width
    private static let H = 7  // glyph height

    // 5×7 bitmaps — each row is 5 bits, 7 rows per glyph
    private static let glyphs: [Character: [UInt8]] = [
        "0": [0,1,1,1,0, 1,0,0,1,1, 1,0,1,0,1, 1,1,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "1": [0,0,1,0,0, 0,1,1,0,0, 0,0,1,0,0, 0,0,1,0,0, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "2": [0,1,1,1,0, 1,0,0,0,1, 0,0,1,1,0, 0,1,0,0,0, 1,1,1,1,1, 0,0,0,0,0, 0,0,0,0,0],
        "3": [0,1,1,1,0, 1,0,0,0,1, 0,0,1,1,0, 1,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "4": [0,0,0,1,0, 0,0,1,1,0, 0,1,0,1,0, 1,1,1,1,1, 0,0,0,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "5": [1,1,1,1,1, 1,0,0,0,0, 1,1,1,1,0, 0,0,0,0,1, 1,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "6": [0,1,1,1,0, 1,0,0,0,0, 1,1,1,1,0, 1,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "7": [1,1,1,1,1, 0,0,0,0,1, 0,0,0,1,0, 0,0,1,0,0, 0,0,1,0,0, 0,0,0,0,0, 0,0,0,0,0],
        "8": [0,1,1,1,0, 1,0,0,0,1, 0,1,1,1,0, 1,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "9": [0,1,1,1,0, 1,0,0,0,1, 0,1,1,1,1, 0,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "A": [0,0,1,0,0, 0,1,0,1,0, 1,0,0,0,1, 1,1,1,1,1, 1,0,0,0,1, 0,0,0,0,0, 0,0,0,0,0],
        "B": [1,1,1,1,0, 1,0,0,0,1, 1,1,1,1,0, 1,0,0,0,1, 1,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "C": [0,1,1,1,0, 1,0,0,0,1, 1,0,0,0,0, 1,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "D": [1,1,1,1,0, 1,0,0,0,1, 1,0,0,0,1, 1,0,0,0,1, 1,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "E": [1,1,1,1,1, 1,0,0,0,0, 1,1,1,1,0, 1,0,0,0,0, 1,1,1,1,1, 0,0,0,0,0, 0,0,0,0,0],
        "F": [1,1,1,1,1, 1,0,0,0,0, 1,1,1,1,0, 1,0,0,0,0, 1,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0],
        "G": [0,1,1,1,0, 1,0,0,0,0, 1,0,0,1,1, 1,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "H": [1,0,0,0,1, 1,0,0,0,1, 1,1,1,1,1, 1,0,0,0,1, 1,0,0,0,1, 0,0,0,0,0, 0,0,0,0,0],
        "I": [0,1,1,1,0, 0,0,1,0,0, 0,0,1,0,0, 0,0,1,0,0, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "K": [1,0,0,1,0, 1,0,1,0,0, 1,1,0,0,0, 1,0,1,0,0, 1,0,0,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "L": [1,0,0,0,0, 1,0,0,0,0, 1,0,0,0,0, 1,0,0,0,0, 1,1,1,1,1, 0,0,0,0,0, 0,0,0,0,0],
        "N": [1,0,0,0,1, 1,1,0,0,1, 1,0,1,0,1, 1,0,0,1,1, 1,0,0,0,1, 0,0,0,0,0, 0,0,0,0,0],
        "O": [0,1,1,1,0, 1,0,0,0,1, 1,0,0,0,1, 1,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "P": [1,1,1,1,0, 1,0,0,0,1, 1,1,1,1,0, 1,0,0,0,0, 1,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0],
        "R": [1,1,1,1,0, 1,0,0,0,1, 1,1,1,1,0, 1,0,0,1,0, 1,0,0,0,1, 0,0,0,0,0, 0,0,0,0,0],
        "S": [0,1,1,1,1, 1,0,0,0,0, 0,1,1,1,0, 0,0,0,0,1, 1,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "T": [1,1,1,1,1, 0,0,1,0,0, 0,0,1,0,0, 0,0,1,0,0, 0,0,1,0,0, 0,0,0,0,0, 0,0,0,0,0],
        "U": [1,0,0,0,1, 1,0,0,0,1, 1,0,0,0,1, 1,0,0,0,1, 0,1,1,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "W": [1,0,0,0,1, 1,0,0,0,1, 1,0,1,0,1, 1,0,1,0,1, 0,1,0,1,0, 0,0,0,0,0, 0,0,0,0,0],
        "X": [1,0,0,0,1, 0,1,0,1,0, 0,0,1,0,0, 0,1,0,1,0, 1,0,0,0,1, 0,0,0,0,0, 0,0,0,0,0],
        "/": [0,0,0,0,1, 0,0,0,1,0, 0,0,1,0,0, 0,1,0,0,0, 1,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0],
        "-": [0,0,0,0,0, 0,0,0,0,0, 1,1,1,1,1, 0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0],
        " ": [0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0, 0,0,0,0,0],
    ]

    var body: some View {
        let chars = Array(text.uppercased())
        let px = pixelSize
        let gap: CGFloat = px

        Canvas { ctx, size in
            var xOff: CGFloat = 0
            for ch in chars {
                guard let glyph = Self.glyphs[ch] else {
                    xOff += 3 * px
                    continue
                }
                for row in 0..<Self.H {
                    for col in 0..<Self.W {
                        if glyph[row * Self.W + col] == 1 {
                            let rect = CGRect(x: xOff + CGFloat(col) * px, y: CGFloat(row) * px, width: px, height: px)
                            ctx.fill(Path(rect), with: .color(color))
                        }
                    }
                }
                xOff += CGFloat(Self.W) * px + gap
            }
        }
        .frame(width: charWidth(chars.count), height: CGFloat(Self.H) * pixelSize)
    }

    private func charWidth(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let px = pixelSize
        return CGFloat(count) * (CGFloat(Self.W) * px + px) - px
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: - Shared Helpers

private let cliIconFiles: [String: String] = [
    "claude": "claude",
    "codex": "codex",
    "gemini": "gemini",
    "antigravity": "claude",
    "cursor": "cursor",
    "trae": "cursor",
    "traecn": "cursor",
    "copilot": "copilot",
    "qoder": "qoder",
    "droid": "factory",
    "codebuddy": "codebuddy",
    "codybuddycn": "codebuddy",
    "stepfun": "claude",
    "workbuddy": "claude",
    "hermes": "claude",
    "opencode": "opencode",
]

private var cliIconCache: [String: NSImage] = [:]

func cliIcon(source: String, size: CGFloat = 16) -> NSImage? {
    let key = "\(source)_\(Int(size))"
    if let cached = cliIconCache[key] { return cached }
    guard let filename = cliIconFiles[source],
          let url = Bundle.appModule.url(forResource: filename, withExtension: "png", subdirectory: "Resources/cli-icons"),
          let image = NSImage(contentsOf: url)
    else { return nil }
    image.size = NSSize(width: size, height: size)
    cliIconCache[key] = image
    return image
}

private struct SessionTag: View {
    let text: String
    var color: Color = .white.opacity(0.7)

    init(_ text: String, color: Color = .white.opacity(0.7)) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(color.opacity(0.12))
            )
    }
}

// MARK: - Typing Indicator (three bouncing dots)

private struct TypingIndicator: View {
    let fontSize: CGFloat
    var label: String? = nil
    var bright: Bool = false
    var color: Color? = nil
    @State private var phase: CGFloat = -60

    var body: some View {
        if let label {
            let baseColor: Color = color ?? .white
            let baseOpacity: Double = bright ? 0.6 : 0.35
            let peakOpacity: Double = bright ? 0.8 : 0.5
            let midOpacity: Double = bright ? 0.5 : 0.3
            let bandWidth: CGFloat = bright ? 80 : 60
            let duration: Double = 2.5
            let endPhase: CGFloat = bright ? 100 : 80
            let startPhase: CGFloat = bright ? -80 : -60

            Text(label)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(baseColor.opacity(baseOpacity))
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(midOpacity), location: bright ? 0.35 : 0.4),
                            .init(color: .white.opacity(peakOpacity), location: 0.5),
                            .init(color: .white.opacity(midOpacity), location: bright ? 0.65 : 0.6),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: bandWidth)
                    .offset(x: phase)
                    .mask(
                        Text(label)
                            .font(.system(size: fontSize, design: .monospaced))
                    )
                )
                .onAppear {
                    phase = startPhase
                    withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: false)) {
                        phase = endPhase
                    }
                }
                .onDisappear { phase = startPhase }
        }
    }
}

// MARK: - Mini Agent Icon (8-bit robot head)

struct MiniAgentIcon: View {
    let active: Bool
    var size: CGFloat = 12

    // 0=empty, 1=body, 2=eye, 3=antenna tip, 4=highlight, 5=shadow
    private let grid: [[Int]] = [
        [0, 0, 0, 3, 0, 0, 0],  // antenna tip (glows)
        [0, 0, 0, 1, 0, 0, 0],  // antenna stem
        [0, 4, 1, 1, 1, 5, 0],  // head top
        [0, 1, 2, 1, 2, 1, 0],  // eyes
        [0, 1, 1, 1, 1, 1, 0],  // face
        [0, 5, 1, 0, 1, 5, 0],  // mouth
        [0, 0, 1, 0, 1, 0, 0],  // legs
    ]

    var body: some View {
        let base = active ? Color.green : Color.gray
        let bright = active ? Color(red: 0.5, green: 1.0, blue: 0.5) : Color(white: 0.7)
        let dark = active ? Color(red: 0.1, green: 0.5, blue: 0.15) : Color(white: 0.35)
        let eye = active ? Color.white : Color(white: 0.85)
        let glow = active ? Color(red: 0.4, green: 1.0, blue: 0.4) : Color(white: 0.6)

        Canvas { ctx, sz in
            let px = sz.width / 7
            for row in 0..<7 {
                for col in 0..<7 {
                    let v = grid[row][col]
                    guard v != 0 else { continue }
                    let color: Color = switch v {
                    case 2: eye
                    case 3: glow
                    case 4: bright
                    case 5: dark
                    default: base
                    }
                    ctx.fill(
                        Path(CGRect(x: CGFloat(col) * px, y: CGFloat(row) * px, width: px, height: px)),
                        with: .color(color)
                    )
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: active ? .green.opacity(0.4) : .clear, radius: 2)
    }
}

// MARK: - Shared Helpers

/// Inline markdown rendering (bold, italic, code, links)
private var markdownCache: [String: AttributedString] = [:]
private let markdownCacheLimit = 128

private func inlineMarkdown(_ text: String) -> AttributedString {
    if let cached = markdownCache[text] { return cached }
    let result: AttributedString
    if let attr = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
        result = attr
    } else {
        result = AttributedString(text)
    }
    if markdownCache.count >= markdownCacheLimit {
        markdownCache.removeAll(keepingCapacity: true)
    }
    markdownCache[text] = result
    return result
}

/// Generate a short session ID with better disambiguation.
private func shortSessionId(_ id: String) -> String {
    let clean = id.replacingOccurrences(of: "-", with: "")
    if clean.count >= 8 {
        return String(clean.suffix(4))
    }
    return String(id.prefix(4))
}

/// Strip internal directives (::code-comment{}, ::git-*{}, etc.) from message text
/// so they don't leak into the UI preview.
// MARK: - Chat Message Row (extracted for render-skip optimization)

/// Separate view so SwiftUI skips body re-evaluation when only the parent's
/// hover state changes — avoids expensive text processing on every hover.
private struct ChatMessageRow: View, Equatable {
    let text: String
    let isUser: Bool
    let fontSize: CGFloat
    let aiLineLimit: Int?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.isUser == rhs.isUser
        && lhs.fontSize == rhs.fontSize && lhs.aiLineLimit == rhs.aiLineLimit
    }

    var body: some View {
        if isUser {
            HStack(alignment: .top, spacing: 4) {
                Text(">")
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.4))
                Text(ChatMessageTextFormatter.literalText(text))
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            HStack(alignment: .top, spacing: 4) {
                Text("$")
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                Text(ChatMessageTextFormatter.inlineMarkdown(compactText(stripDirectives(text))))
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(aiLineLimit)
                    .truncationMode(.tail)
            }
        }
    }

    private func compactText(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .reduce(into: [String]()) { result, line in
                if line.isEmpty && (result.last?.isEmpty ?? true) { return }
                result.append(line)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func stripDirectives(_ text: String) -> String {
    // Match ::directive-name{...} patterns (may span multiple lines)
    // Use a simple approach: remove lines that start with ::word{ or are continuation of a directive
    var result: [String] = []
    var inDirective = false
    var braceDepth = 0

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if inDirective {
            for ch in line {
                if ch == "{" { braceDepth += 1 }
                if ch == "}" { braceDepth -= 1 }
            }
            if braceDepth <= 0 {
                inDirective = false
                braceDepth = 0
            }
            continue
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("::") && trimmed.contains("{") {
            // Count braces to handle single-line vs multi-line directives
            braceDepth = 0
            for ch in line {
                if ch == "{" { braceDepth += 1 }
                if ch == "}" { braceDepth -= 1 }
            }
            if braceDepth > 0 {
                inDirective = true
            }
            // Either way, skip this line
            continue
        }
        result.append(String(line))
    }

    let cleaned = result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned
}

// MARK: - Approval Bar (interactive via hook OR read-only jump-to-terminal)

private struct ApprovalBar: View {
    let tool: String
    let detail: String?
    let sessionSource: String?
    let projectName: String?
    let queueCount: Int
    /// When true, show Allow/Deny/Always buttons (hook-based).
    /// When false, show "Approve in Terminal" (passive detection only).
    let isInteractive: Bool
    let onJumpToTerminal: () -> Void
    let onAllow: () -> Void
    let onAllowAlways: () -> Void
    let onDeny: () -> Void

    private let amber = Color(red: 1.0, green: 0.7, blue: 0.28)

    var body: some View {
        VStack(spacing: 8) {
            // Context row: source icon + project name
            HStack(spacing: 6) {
                if let src = sessionSource, let icon = cliIcon(source: src, size: 12) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
                if let project = projectName {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(project)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
            .padding(.horizontal, 14)

            // Tool name + queue count
            HStack(spacing: 6) {
                Text("!")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(amber)
                Text(tool)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(amber)
                if queueCount > 1 {
                    Text("1/\(queueCount)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
            }
            .padding(.horizontal, 14)

            // Tool detail (command, file path, etc.)
            if let detail, !detail.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Text("$")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.4))
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04))
            }

            // Actions
            if isInteractive {
                // Hook-based: PixelButton with MioIsland-inspired palette + shortcut hints
                HStack(spacing: 6) {
                    // Deny: subtle white/gray (⌘⇧D)
                    PixelButton(label: "\(L10n.shared["deny"]) ⌘⇧D",
                                fg: .white.opacity(0.85),
                                bg: Color.white.opacity(0.08),
                                border: Color.white.opacity(0.2),
                                action: onDeny)
                    // Allow Once: MioIsland green (⌘⇧A)
                    PixelButton(label: "\(L10n.shared["allow_once"]) ⌘⇧A",
                                fg: .black,
                                bg: Color(red: 0.29, green: 0.87, blue: 0.50),
                                border: Color(red: 0.29, green: 0.87, blue: 0.50),
                                action: onAllow)
                    // Always: blue #3B82F6
                    PixelButton(label: L10n.shared["always"],
                                fg: .white,
                                bg: Color(red: 0.22, green: 0.51, blue: 0.96),
                                border: Color(red: 0.22, green: 0.51, blue: 0.96),
                                action: onAllowAlways)
                }
                .padding(.horizontal, 14)
            } else if !HookInstaller.isInstalled() {
                // Passive fallback (no hooks): jump to terminal to act there
                let isQuestion = tool == "AskUserQuestion"
                Button(action: onJumpToTerminal) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 10))
                        Text(isQuestion ? "Answer in Terminal →" : "Approve in Terminal →")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(red: 0.14, green: 0.28, blue: 0.52))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(red: 0.28, green: 0.48, blue: 0.82), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 10)
    }

}

// MARK: - PixelButton

private struct PixelButton: View {
    let label: String
    let fg: Color
    let bg: Color
    let border: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hovering ? bg.opacity(1.5) : bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(hovering ? border : border.opacity(0.4), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { action() }
        .onHover { h in withAnimation(NotchAnimation.micro) { hovering = h } }
    }
}

// MARK: - Question Bar (AskUserQuestion via hook — ported from CodeIsland)

private struct QuestionBar: View {
    let items: [QuestionItem]
    let sessionSource: String?
    let projectName: String?
    let onAnswer: ([String: String]) -> Void
    let onSkip: () -> Void

    @State private var textInput = ""
    @FocusState private var isFocused: Bool
    @State private var selectedIndex: Int? = nil
    @State private var currentQuestionIndex: Int = 0
    @State private var collectedAnswers: [String: String] = [:]
    @State private var showOtherInput: Bool = false
    @State private var otherText: String = ""
    @FocusState private var otherFocused: Bool

    private let cyan = Color(red: 0.4, green: 0.7, blue: 1.0)

    private var currentItem: QuestionItem? {
        guard currentQuestionIndex < items.count else { return nil }
        return items[currentQuestionIndex]
    }

    var body: some View {
        VStack(spacing: 8) {
            // Session context
            HStack(spacing: 5) {
                if let src = sessionSource, let icon = cliIcon(source: src, size: 12) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
                if let project = projectName {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(project)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
            .padding(.horizontal, 14)

            if let item = currentItem {
                // Question header + text
                HStack(spacing: 6) {
                    Text("?")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(cyan)
                    if let header = item.header, !header.isEmpty {
                        Text(header)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(cyan.opacity(0.7))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(cyan.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Text(item.question)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                    Spacer()
                    if items.count > 1 {
                        Text("\(currentQuestionIndex + 1)/\(items.count)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                .padding(.horizontal, 14)

                // Options or text input
                if let opts = item.options, !opts.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(Array(opts.enumerated()), id: \.offset) { idx, option in
                            let desc = item.descriptions?.indices.contains(idx) == true ? item.descriptions?[idx] : nil
                            OptionRow(index: idx + 1, label: option, description: desc,
                                      isSelected: selectedIndex == idx, accent: cyan) {
                                selectedIndex = idx
                                showOtherInput = false
                                advanceWithAnswer(option)
                            }
                        }

                        // "Type something" option (CodeIsland's "Other")
                        OptionRow(index: -1, label: "Type something…", description: nil,
                                  isSelected: showOtherInput, accent: cyan) {
                            showOtherInput = true
                            selectedIndex = nil
                        }

                        // Custom text input (shown when "Type something" is selected)
                        if showOtherInput {
                            HStack(spacing: 6) {
                                Text(">")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.4))
                                TextField(L10n.shared["type_answer"], text: $otherText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .focused($otherFocused)
                                    .onSubmit {
                                        if !otherText.isEmpty { advanceWithAnswer(otherText) }
                                    }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                            )
                            .onAppear { otherFocused = true }
                        }
                    }
                    .padding(.horizontal, 14)
                } else {
                    // No options — text input only
                    HStack(spacing: 6) {
                        Text(">")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.4))
                        TextField(L10n.shared["type_answer"], text: $textInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white)
                            .focused($isFocused)
                            .onSubmit {
                                if !textInput.isEmpty { advanceWithAnswer(textInput) }
                            }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .padding(.horizontal, 14)
                }

                // Buttons
                HStack(spacing: 6) {
                    if currentQuestionIndex > 0 {
                        PixelButton(label: "BACK", fg: .white.opacity(0.6),
                                    bg: Color.white.opacity(0.06), border: Color.white.opacity(0.12),
                                    action: goBack)
                    }
                    PixelButton(label: L10n.shared["skip"], fg: .white.opacity(0.6),
                                bg: Color.white.opacity(0.06), border: Color.white.opacity(0.12),
                                action: onSkip)
                    if showOtherInput {
                        PixelButton(label: L10n.shared["submit"], fg: .white.opacity(0.95),
                                    bg: Color(red: 0.16, green: 0.38, blue: 0.18),
                                    border: Color(red: 0.28, green: 0.62, blue: 0.32),
                                    action: { if !otherText.isEmpty { advanceWithAnswer(otherText) } })
                    } else if item.options == nil || item.options?.isEmpty == true {
                        PixelButton(label: L10n.shared["submit"], fg: .white.opacity(0.95),
                                    bg: Color(red: 0.16, green: 0.38, blue: 0.18),
                                    border: Color(red: 0.28, green: 0.62, blue: 0.32),
                                    action: { if !textInput.isEmpty { advanceWithAnswer(textInput) } })
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 10)
        .onAppear { isFocused = true }
    }

    private func advanceWithAnswer(_ answer: String) {
        guard let item = currentItem else { return }
        collectedAnswers[item.answerKey] = answer

        if currentQuestionIndex + 1 < items.count {
            // Brief pause to show selection, then advance
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(NotchAnimation.micro) {
                    currentQuestionIndex += 1
                    selectedIndex = nil
                    textInput = ""
                    showOtherInput = false
                    otherText = ""
                }
            }
        } else {
            // Brief pause to show checkmark, then submit + dismiss
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(NotchAnimation.close) {
                    onAnswer(collectedAnswers)
                }
            }
        }
    }

    private func goBack() {
        guard currentQuestionIndex > 0 else { return }
        let prevItem = items[currentQuestionIndex - 1]
        collectedAnswers.removeValue(forKey: prevItem.answerKey)
        withAnimation(NotchAnimation.micro) {
            currentQuestionIndex -= 1
            selectedIndex = nil
            textInput = ""
            showOtherInput = false
            otherText = ""
        }
    }
}

// MARK: - OptionRow (ported from CodeIsland)

private struct OptionRow: View {
    let index: Int
    let label: String
    let description: String?
    let isSelected: Bool
    let accent: Color
    let action: () -> Void
    @State private var hovering = false

    private var active: Bool { isSelected || hovering }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // Arrow / checkmark
                Text(isSelected ? "✓" : (hovering ? "▸" : " "))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color(red: 0.29, green: 0.87, blue: 0.50) : accent)
                    .frame(width: 10)
                Text(index > 0 ? "\(index)." : "…")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent.opacity(active ? 1 : 0.6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 10.5, weight: active ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(active ? 1 : 0.75))
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? accent.opacity(0.15) : (hovering ? Color.white.opacity(0.08) : Color.white.opacity(0.03)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? accent.opacity(0.6) : (hovering ? accent.opacity(0.4) : Color.clear), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(NotchAnimation.micro) { hovering = h } }
        .animation(NotchAnimation.micro, value: isSelected)
    }
}
