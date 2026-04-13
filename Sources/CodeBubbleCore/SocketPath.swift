import Foundation

/// Unix socket path used for IPC between the bridge binary and the CodeBubble app.
/// Override via `CODEBUBBLE_SOCKET_PATH` environment variable.
public enum SocketPath {
    public static var path: String {
        if let env = ProcessInfo.processInfo.environment["CODEBUBBLE_SOCKET_PATH"], !env.isEmpty {
            return env
        }
        return "/tmp/codebubble-\(getuid()).sock"
    }
}
