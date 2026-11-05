import Darwin
import Foundation

/// Low-level Unix-domain socket plumbing shared by the server and the bridge.
enum MCPSocket {
    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, terminator included.
    static let maxPathBytes = 103

    enum Failure: Error, Equatable, CustomStringConvertible {
        case pathTooLong(String)
        case system(String, Int32)
        case alreadyListening(String)

        var description: String {
            switch self {
            case .pathTooLong(let path): return "Socket path is too long: \(path)"
            case .system(let call, let code):
                return "\(call) failed: \(POSIXErrorCode(rawValue: code).map { "\(POSIXError($0).localizedDescription)" } ?? "errno \(code)")"
            case .alreadyListening(let path): return "Another Chord is already serving \(path)"
            }
        }
    }

    static func address(for path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathBytes else { throw Failure.pathTooLong(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        // A peer that hangs up mid-write must not kill the app with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Connects to `path`, returning the socket, or throws.
    static func connect(to path: String) throws -> Int32 {
        var address = try address(for: path)
        let fd = try makeSocket()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw Failure.system("connect", code)
        }
        return fd
    }

    /// Writes all of `data`, waiting out a full buffer on a non-blocking socket.
    /// False when the peer is gone.
    @discardableResult
    static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            // A client that stops reading must not hold the writer forever:
            // ten seconds without progress and it counts as gone.
            var stalledPolls = 0
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                    stalledPolls = 0
                } else if written < 0, errno == EAGAIN || errno == EINTR, stalledPolls < 10 {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&poller, 1, 1000) == 0 { stalledPolls += 1 }
                } else {
                    return false
                }
            }
            return true
        }
    }
}

/// The process on the other end of a connection, as the kernel reports it.
public struct MCPPeer: Sendable, Equatable {
    public let pid: pid_t
    public let uid: uid_t
    /// The peer's executable, resolved. Nil when the kernel would not say.
    public let executablePath: String?

    public init(pid: pid_t, uid: uid_t, executablePath: String?) {
        self.pid = pid
        self.uid = uid
        self.executablePath = executablePath
    }

    /// Reads the peer of a connected Unix socket. Nil when it cannot be
    /// established — which the server treats as a refusal.
    static func of(_ fd: Int32) -> MCPPeer? {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0,
              credentials.cr_version == XUCRED_VERSION
        else { return nil }

        var pid: pid_t = 0
        length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }

        return MCPPeer(pid: pid, uid: credentials.cr_uid, executablePath: executablePath(of: pid))
    }

    static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a macro Swift can't see.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }
        return resolved(String(decoding: bytes, as: UTF8.self))
    }

    static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return FileManager.default.string(withFileSystemRepresentation: real, length: strlen(real))
    }
}

/// Who may connect.
public enum MCPPeerPolicy: Sendable {
    /// Same user, and the peer runs exactly `executablePath` — Chord's own
    /// binary in its `--mcp-stdio` mode. Anything else the user runs has to go
    /// through that helper, which an MCP client launches on the user's say-so.
    case sameUserRunning(executablePath: String)
    /// Same user, any executable. Tests only: a test's peer is the test runner.
    case sameUser

    func allows(_ peer: MCPPeer) -> Bool {
        guard peer.uid == getuid() else { return false }
        switch self {
        case .sameUser:
            return true
        case .sameUserRunning(let path):
            return peer.executablePath == MCPPeer.resolved(path)
        }
    }
}
