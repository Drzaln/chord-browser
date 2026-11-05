import Darwin
import Foundation
import Testing

@testable import ChordMCP

/// The real socket: bind, permissions, peer check, line framing, the bridge.
@Suite("MCP socket server", .serialized)
struct MCPSocketServerTests {
    /// Short, because `sun_path` is 104 bytes and the test temp dir is long.
    private static func makeSocketPath() -> String {
        "/tmp/chord-mcp-\(getpid())-\(UUID().uuidString.prefix(8))/s.sock"
    }

    private func makeServer(
        path: String, policy: MCPPeerPolicy = .sameUser,
        onChange: @escaping @Sendable (Int) -> Void = { _ in }
    ) -> MCPSocketServer {
        MCPSocketServer(
            socketPath: path,
            handler: MCPProtocolHandler(provider: EchoProvider(), serverName: "chord", serverVersion: "1"),
            peerPolicy: policy,
            onConnectionsChanged: onChange
        )
    }

    /// Writes one line and reads one line back, with a timeout.
    private func roundTrip(_ line: String, on fd: Int32) -> String? {
        MCPSocket.writeAll(Data((line + "\n").utf8), to: fd)
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 200) > 0 else { continue }
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return nil }
            received.append(contentsOf: chunk[0..<count])
            if let newline = received.firstIndex(of: 0x0A) {
                return String(decoding: received[..<newline], as: UTF8.self)
            }
        }
        return nil
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Answers a request over the socket, which only the user can reach")
    func roundTripAndPermissions() throws {
        let path = Self.makeSocketPath()
        let server = makeServer(path: path)
        try server.start()
        defer { server.stop() }

        var info = stat()
        #expect(stat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(stat((path as NSString).deletingLastPathComponent, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)

        let fd = try MCPSocket.connect(to: path)
        defer { close(fd) }
        let reply = try #require(roundTrip(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, on: fd))
        let json = try decode(Data(reply.utf8))
        #expect(json["id"] == 1)
        #expect(json["result"] == [:])
    }

    @Test("A peer that isn't Chord's helper is hung up on unanswered")
    func refusesOtherExecutables() throws {
        let path = Self.makeSocketPath()
        let server = makeServer(path: path, policy: .sameUserRunning(executablePath: "/usr/bin/false"))
        try server.start()
        defer { server.stop() }

        let fd = try MCPSocket.connect(to: path)
        defer { close(fd) }
        #expect(roundTrip(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, on: fd) == nil)
        #expect(server.connectionCount == 0)
    }

    @Test("The peer check sees this very process")
    func peerIsThisProcess() throws {
        let path = Self.makeSocketPath()
        let server = makeServer(
            path: path,
            policy: .sameUserRunning(executablePath: MCPPeer.executablePath(of: getpid()) ?? "?")
        )
        try server.start()
        defer { server.stop() }

        let fd = try MCPSocket.connect(to: path)
        defer { close(fd) }
        #expect(roundTrip(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, on: fd) != nil)
    }

    @Test("A second server on a live socket refuses; a stale one is replaced")
    func secondServer() throws {
        let path = Self.makeSocketPath()
        let first = makeServer(path: path)
        try first.start()
        #expect(throws: MCPSocket.Failure.alreadyListening(path)) { try makeServer(path: path).start() }
        first.stop()

        // A leftover socket file with nobody behind it, as a crash leaves.
        var address = try MCPSocket.address(for: path)
        let stale = try MCPSocket.makeSocket()
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(stale)
        #expect(MCPSocketServer.isSocket(path))

        let second = makeServer(path: path)
        try second.start()
        second.stop()
        #expect(!MCPSocketServer.isSocket(path))
    }

    @Test("Connection count tracks clients, and Disconnect hangs up on them")
    func disconnectAll() async throws {
        let path = Self.makeSocketPath()
        let counts = Counts()
        let server = makeServer(path: path) { counts.append($0) }
        try server.start()
        defer { server.stop() }

        let fd = try MCPSocket.connect(to: path)
        defer { close(fd) }
        await waitUntil { server.connectionCount == 1 }
        #expect(server.connectionCount == 1)

        server.disconnectAll()
        #expect(server.connectionCount == 0)
        var byte: UInt8 = 0
        #expect(read(fd, &byte, 1) == 0)  // EOF: the server closed its end
        #expect(counts.values.last == 0)
    }

    @Test("A path that won't fit sun_path is refused up front")
    func longPath() {
        let path = "/tmp/" + String(repeating: "x", count: 200) + "/s.sock"
        #expect(throws: MCPSocket.Failure.pathTooLong(path)) { try makeServer(path: path).start() }
    }

    @Test("The stdio bridge carries a request in and the reply out")
    func bridge() async throws {
        let path = Self.makeSocketPath()
        let server = makeServer(path: path)
        try server.start()
        defer { server.stop() }

        let input = Pipe()
        let output = Pipe()
        let status = Task.detached {
            MCPStdioBridge.run(
                socketPath: path,
                input: input.fileHandleForReading.fileDescriptor,
                output: output.fileHandleForWriting.fileDescriptor
            )
        }
        input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#.utf8 + [0x0A]))

        let line = try #require(readLine(from: output.fileHandleForReading.fileDescriptor))
        #expect(try decode(Data(line.utf8))["id"] == 9)

        // Chord hanging up ends the helper.
        await waitUntil { server.connectionCount == 1 }
        server.disconnectAll()
        #expect(await status.value == 0)
    }

    @Test("The bridge fails with a hint when Chord isn't listening")
    func bridgeWithoutChord() {
        let errors = Pipe()
        let status = MCPStdioBridge.run(
            socketPath: Self.makeSocketPath(),
            diagnostics: errors.fileHandleForWriting.fileDescriptor
        )
        errors.fileHandleForWriting.closeFile()
        #expect(status == 1)
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(message.contains("Allow local agents"))
    }

    private func readLine(from fd: Int32) -> String? {
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 200) > 0 else { continue }
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return nil }
            received.append(contentsOf: chunk[0..<count])
            if let newline = received.firstIndex(of: 0x0A) {
                return String(decoding: received[..<newline], as: UTF8.self)
            }
        }
        return nil
    }
}

final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    func append(_ value: Int) { lock.withLock { stored.append(value) } }
    var values: [Int] { lock.withLock { stored } }
}
