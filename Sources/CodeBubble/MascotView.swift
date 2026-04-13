import SwiftUI
import CodeBubbleCore

// MARK: - Mascot Animation Speed Environment

private struct MascotSpeedKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var mascotSpeed: Double {
        get { self[MascotSpeedKey.self] }
        set { self[MascotSpeedKey.self] = newValue }
    }
}

/// Routes a CLI source identifier to the correct pixel mascot view.
struct MascotView: View {
    let source: String
    let status: AgentStatus
    var size: CGFloat = 27
    @AppStorage(SettingsKey.mascotSpeed) private var speedPct = SettingsDefaults.mascotSpeed

    var body: some View {
        Group {
            switch source {
            case "codex":
                CodexView(status: status, size: size)
            case "opencode":
                OpenCodeView(status: status, size: size)
            default:
                ClawdView(status: status, size: size)
            }
        }
        .environment(\.mascotSpeed, Double(speedPct) / 100.0)
    }
}
