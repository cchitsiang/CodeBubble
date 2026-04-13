import Foundation
import os.log

@MainActor
final class SessionMonitor {
    private static let log = Logger(subsystem: "com.codebubble", category: "SessionMonitor")
    private let providers: [SessionProvider]
    private weak var appState: AppState?
    private var timer: Timer?
    private let pollInterval: TimeInterval = 3.0

    init(appState: AppState) {
        self.appState = appState
        self.providers = [
            ClaudeProvider(),
            CodexProvider(),
            OpenCodeProvider(),
        ]
    }

    func start() {
        Self.log.info("SessionMonitor starting with \(self.providers.count) providers")
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let appState else { return }
        var allSessions: [AgentSession] = []
        for provider in providers {
            let discovered = provider.discoverSessions()
            allSessions.append(contentsOf: discovered)
        }
        appState.updateFromProviders(allSessions)
    }
}
