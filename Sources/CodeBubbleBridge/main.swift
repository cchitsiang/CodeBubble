//
//  codebubble-bridge — Minimal hook bridge for Claude Code PermissionRequest
//
//  Reads JSON from stdin, forwards to CodeBubble app via Unix socket, waits for
//  approval/deny response, and writes the response to stdout so Claude Code
//  can act on the user's decision.
//
//  Usage: installed as ~/.claude/hooks/codebubble-bridge by the main app.
//

import Foundation
import Darwin
import CodeBubbleCore

// MARK: - Constants

let SOCKET_PATH = SocketPath.path
let CONNECT_TIMEOUT_SEC: Int32 = 3
let RESPONSE_TIMEOUT_SEC: Int32 = 86400  // 24 hours — user may take long to respond

// Ignore SIGPIPE globally so writes to a closed socket return EPIPE instead of killing us.
signal(SIGPIPE, SIG_IGN)

// MARK: - Read stdin

guard let stdinData = try? FileHandle.standardInput.readToEnd(),
      !stdinData.isEmpty else {
    // No input — exit cleanly so Claude Code proceeds with its default behavior
    exit(0)
}

// MARK: - Connect to Unix socket

let sock = socket(AF_UNIX, SOCK_STREAM, 0)
guard sock >= 0 else { exit(0) }

// Disable SIGPIPE for this socket
var noSigpipe: Int32 = 1
setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

// Build sockaddr_un
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(SOCKET_PATH.utf8CString)
guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { exit(0) }
withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
    ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { cptr in
        pathBytes.withUnsafeBufferPointer { src in
            _ = memcpy(cptr, src.baseAddress, pathBytes.count)
        }
    }
}
let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

// Set connect timeout via SO_SNDTIMEO (non-blocking connect would be cleaner but this is simpler)
var timeout = timeval(tv_sec: Int(CONNECT_TIMEOUT_SEC), tv_usec: 0)
setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        connect(sock, sockPtr, addrLen)
    }
}

guard connectResult == 0 else {
    // App not running or socket not available → exit cleanly so Claude continues
    close(sock)
    exit(0)
}

// MARK: - Send event

_ = stdinData.withUnsafeBytes { bytes -> Int in
    guard let base = bytes.baseAddress else { return -1 }
    var sent = 0
    let total = bytes.count
    while sent < total {
        let remaining = total - sent
        let result = send(sock, base.advanced(by: sent), remaining, 0)
        if result <= 0 { return sent }
        sent += result
    }
    return sent
}

// Half-close write side to signal EOF to the server
shutdown(sock, Int32(SHUT_WR))

// MARK: - Wait for response

// Set long timeout for receiving user decision
var recvTimeout = timeval(tv_sec: Int(RESPONSE_TIMEOUT_SEC), tv_usec: 0)
setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

var responseData = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while true {
    let n = recv(sock, &buffer, buffer.count, 0)
    if n <= 0 { break }
    responseData.append(buffer, count: n)
}

close(sock)

// MARK: - Write response to stdout

if !responseData.isEmpty {
    try? FileHandle.standardOutput.write(contentsOf: responseData)
}

exit(0)
