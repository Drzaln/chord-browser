import ChordLogging
import Darwin
import Foundation

enum Log {
    static let mcp = AppLog.category("mcp")
}

/// Serves MCP over a Unix-domain socket, one newline-delimited JSON-RPC
/// message per line (the stdio transport's framing, so the `--mcp-stdio`
/// helper only has to copy bytes).
///
/// Local only by construction: there is no TCP listener at all. The socket
/// sits in a directory only the user can enter (0700) and is itself 0600, and
/// every connection's peer is checked against `peerPolicy` before a byte of it
/// is read.
public final class MCPSocketServer: @unchecked Sendable {
    public let socketPath: String
    private let handler: MCPProtocolHandler
    private let peerPolicy: MCPPeerPolicy
    private let onConnectionsChanged: @Sendable (Int) -> Void

    /// Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "com.rizal.chord.mcp")
    private var listenSource: (any DispatchSourceRead)?
    private var connections: [ObjectIdentifier: Connection] = [:]

    /// A line longer than this is not an MCP request; the connection is dropped.
    static let maxLineBytes = 4 * 1024 * 1024

    public init(
        socketPath: String,
        handler: MCPProtocolHandler,
        peerPolicy: MCPPeerPolicy,
        onConnectionsChanged: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.socketPath = socketPath
        self.handler = handler
        self.peerPolicy = peerPolicy
        self.onConnectionsChanged = onConnectionsChanged
    }

    deinit {
        listenSource?.cancel()
    }

    public func start() throws {
        try queue.sync { try startOnQueue() }
    }

    public func stop() {
        queue.sync {
            listenSource?.cancel()
            listenSource = nil
            closeAllOnQueue()
            if MCPSocketServer.isSocket(socketPath) { unlink(socketPath) }
        }
    }

    /// Hangs up on every client but keeps listening — the indicator's
    /// "Disconnect". A client that wants back in reconnects through its helper.
    public func disconnectAll() {
        queue.sync { closeAllOnQueue() }
    }

    public var connectionCount: Int {
        queue.sync { connections.count }
    }

    // MARK: - Listening

    private func startOnQueue() throws {
        guard listenSource == nil else { return }

        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Tighten an existing directory too, in case it predates this code.
        chmod(directory, 0o700)

        if MCPSocketServer.isSocket(socketPath) {
            // A live listener means a second Chord; a dead one is a leftover
            // from a crash, and binding over it needs it gone.
            if let fd = try? MCPSocket.connect(to: socketPath) {
                close(fd)
                throw MCPSocket.Failure.alreadyListening(socketPath)
            }
            unlink(socketPath)
        }

        var address = try MCPSocket.address(for: socketPath)
        let fd = try MCPSocket.makeSocket()
        // umask the bind so the socket is never reachable at wider permissions,
        // not even for the instant before the chmod.
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw MCPSocket.Failure.system("bind", code)
        }
        chmod(socketPath, 0o600)
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw MCPSocket.Failure.system("listen", code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { close(fd) }
        listenSource = source
        source.resume()
        Log.mcp.notice("listening on \(self.socketPath)")
    }

    private func acceptPending(on listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }

            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            guard let peer = MCPPeer.of(fd), peerPolicy.allows(peer) else {
                let path = MCPPeer.of(fd)?.executablePath ?? "unknown"
                Log.mcp.notice("refused connection from \(path)")
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

            let connection = Connection(fd: fd, queue: queue, handler: handler)
            let key = ObjectIdentifier(connection)
            connection.onClose = { [weak self] in
                guard let self else { return }
                if self.connections.removeValue(forKey: key) != nil {
                    self.onConnectionsChanged(self.connections.count)
                }
            }
            connections[key] = connection
            connection.start()
            Log.mcp.notice("agent connected (pid \(peer.pid))")
            onConnectionsChanged(connections.count)
        }
    }

    private func closeAllOnQueue() {
        let open = connections.values
        connections.removeAll()
        open.forEach { $0.close() }
        if !open.isEmpty { onConnectionsChanged(0) }
    }

    static func isSocket(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK
    }
}

/// One client: reads lines, answers each through the handler, writes replies
/// back in whatever order they finish (JSON-RPC matches them by id).
private final class Connection: @unchecked Sendable {
    let fd: Int32
    let queue: DispatchQueue
    let handler: MCPProtocolHandler
    /// Called on `queue` once, when the connection ends for any reason.
    var onClose: (() -> Void)?

    private var source: (any DispatchSourceRead)?
    private var buffer = Data()
    /// Guarded by `writeLock`. Replies are written from tasks; the lock keeps
    /// two from interleaving bytes and a write from racing the close.
    private var isClosed = false
    private let writeLock = NSLock()

    init(fd: Int32, queue: DispatchQueue, handler: MCPProtocolHandler) {
        self.fd = fd
        self.queue = queue
        self.handler = handler
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        let fd = self.fd
        // `close()` marks the connection closed under the write lock before it
        // cancels, so no reply can still be writing to this descriptor when it
        // is released here.
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    /// On `queue`.
    func close() {
        writeLock.lock()
        let wasClosed = isClosed
        isClosed = true
        writeLock.unlock()
        guard !wasClosed else { return }
        source?.cancel()
        source = nil
        onClose?()
        onClose = nil
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count < 0, errno == EAGAIN || errno == EINTR {
                break
            } else {
                close()
                return
            }
        }

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x0D })
            if !trimmed.isEmpty { dispatch(Data(line)) }
        }
        if buffer.count > MCPSocketServer.maxLineBytes {
            Log.mcp.notice("dropping a client that sent an oversized line")
            close()
        }
    }

    private func dispatch(_ line: Data) {
        let handler = self.handler
        Task { [weak self] in
            guard let reply = await handler.handle(line) else { return }
            self?.send(reply + Data([0x0A]))
        }
    }

    private func send(_ data: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { return }
        MCPSocket.writeAll(data, to: fd)
    }
}
