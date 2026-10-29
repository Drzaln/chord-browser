import Darwin
import Foundation
import WebKit

/// Chrome's native-messaging protocol, for extensions that talk to an app on
/// this Mac — a password manager unlocking with its desktop app, a clipper
/// handing a page to a notes app.
///
/// Those apps register with Chrome by leaving a JSON file in Chrome's
/// `NativeMessagingHosts` folder: a name, the program to run, and which
/// extensions may run it. Chord reads the same files, runs the same program
/// with the same origin argument, and speaks the same protocol — a four-byte
/// little-endian length and a JSON body over stdin/stdout.
///
/// A host that lists the extension's id among its allowed origins is run; any
/// other is not. Some hosts also check which browser is calling and may refuse
/// one they do not know; that is theirs to decide.
@MainActor
enum ExtensionNative {
    struct Refused: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// Where Chromium browsers look, per user and for the whole Mac.
    static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")
        return [
            support.appendingPathComponent("Google/Chrome/NativeMessagingHosts"),
            support.appendingPathComponent("Chromium/NativeMessagingHosts"),
            support.appendingPathComponent("Microsoft Edge/NativeMessagingHosts"),
            support.appendingPathComponent("BraveSoftware/Brave-Browser/NativeMessagingHosts"),
            support.appendingPathComponent("Arc/User Data/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Application Support/Chromium/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Microsoft/Edge/NativeMessagingHosts"),
            support.appendingPathComponent("Vivaldi/NativeMessagingHosts"),
            support.appendingPathComponent("com.operasoftware.Opera/NativeMessagingHosts"),
        ]
    }

    /// The program for `name`, if one is registered and lets `extensionID` in.
    /// Kept internal and split from `folders` so the allow-list rules can be
    /// tested without touching the real Chrome folders.
    static func host(
        named name: String, in folders: [URL], extensionID: String
    ) throws -> URL {
        guard name.range(
            of: #"^[a-z0-9_]+(\.[a-z0-9_]+)*$"#, options: .regularExpression
        ) != nil else {
            throw Refused(why: "Invalid native messaging host name")
        }
        let origin = "chrome-extension://\(extensionID)/"
        for folder in folders {
            let file = folder.appendingPathComponent(name + ".json")
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = manifest["path"] as? String
            else { continue }
            let allowed = manifest["allowed_origins"] as? [String] ?? []
            guard allowed.contains(origin) else {
                throw Refused(why: "Access to the specified native messaging host is forbidden.")
            }
            let program = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
            guard FileManager.default.isExecutableFile(atPath: program.path) else {
                throw Refused(why: "Specified native messaging host not found.")
            }
            return program
        }
        throw Refused(why: "Specified native messaging host not found.")
    }

    /// `runtime.sendNativeMessage`: run, send one, read one, stop.
    static func send(
        _ message: Any, to name: String, from extensionID: String
    ) async throws -> Any? {
        let program = try host(named: name, in: folders, extensionID: extensionID)
        let pipe = HostPipe(
            program: program, origin: "chrome-extension://\(extensionID)/"
        )
        try pipe.start()
        defer { pipe.stop() }
        let encoded = try JSONSerialization.data(
            withJSONObject: message, options: [.fragmentsAllowed]
        )
        let reply = try await pipe.request(encoded)
        return try JSONSerialization.jsonObject(
            with: reply, options: [.fragmentsAllowed]
        )
    }

    /// `runtime.connectNative`: run, and keep the two talking until either end
    /// lets go.
    static func connect(
        _ port: WKWebExtension.MessagePort, named name: String, from extensionID: String
    ) throws {
        let program = try host(named: name, in: folders, extensionID: extensionID)
        stopOrphans()
        let pipe = HostPipe(
            program: program, origin: "chrome-extension://\(extensionID)/"
        )
        pipe.onMessage = { data in
            let message = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]
            )
            DispatchQueue.main.async {
                port.sendMessage(message, completionHandler: nil)
            }
        }
        pipe.onExit = {
            DispatchQueue.main.async { if !port.isDisconnected { port.disconnect() } }
        }
        Live.keep(pipe, for: port)
        do { try pipe.start() } catch {
            pipe.stop()
            throw error
        }
        var beating: Timer?
        port.messageHandler = { message, _ in
            guard let message else { return }
            // A worker's shim asking whether the port has arrived (see the
            // shim, after its WebSocket): answered here, never passed on.
            // Unanswered, the shim held everything the extension posted for
            // some ten seconds before sending it anyway, so Bitwarden's
            // biometric unlock waited that long for its Touch ID prompt.
            if let word = shimWord(in: message) {
                // The shim's answer to "alive" (below) is only the worker
                // keeping itself: nothing to say back.
                guard word == .asked else { return }
                port.sendMessage(["__chordNative": "here"], completionHandler: nil)
                // Asked, it is a worker's port, and WebKit unloads a worker
                // that hasn't posted on a port for two minutes. Chrome keeps
                // a worker with a port to an app alive; here a word on the
                // port now and then, heard only by the shim, has the worker
                // answer on it, which is what WebKit counts.
                if beating == nil {
                    // Scheduled from the port's handler, on the main run loop.
                    beating = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { timer in
                        let gone = MainActor.assumeIsolated {
                            if port.isDisconnected { return true }
                            port.sendMessage(["__chordNative": "alive"], completionHandler: nil)
                            return false
                        }
                        if gone { timer.invalidate() }
                    }
                }
                return
            }
            guard let data = try? JSONSerialization.data(
                withJSONObject: message, options: [.fragmentsAllowed]
            ) else { return }
            try? pipe.write(data)
        }
        port.disconnectHandler = { _ in beating?.invalidate(); pipe.stop() }
    }

    /// What the worker's shim says to the browser on a native port, which
    /// the host never hears: whether the port has arrived, or its answer to
    /// the browser's "alive".
    enum ShimWord { case asked, other }

    static func shimWord(in message: Any) -> ShimWord? {
        guard let message = message as? [String: Any],
              let word = message["__chordNative"]
        else { return nil }
        return (word as? String) == "here?" ? .asked : .other
    }

    /// WebKit does not always call a port's disconnect handler when an
    /// extension is unloaded. Stop the hosts of ports that have gone so a
    /// helper with a prompt open does not outlive the browser.
    static func stopOrphans() {
        for (pipe, port) in Live.pipes.values where port.isDisconnected {
            pipe.stop()
        }
    }

    /// Hosts that are connected, held until they end.
    private enum Live {
        nonisolated(unsafe) static var pipes:
            [ObjectIdentifier: (pipe: HostPipe, port: WKWebExtension.MessagePort)] = [:]

        static func keep(_ pipe: HostPipe, for port: WKWebExtension.MessagePort) {
            pipes[ObjectIdentifier(pipe)] = (pipe, port)
            let previous = pipe.onExit
            pipe.onExit = {
                previous?()
                DispatchQueue.main.async { pipes[ObjectIdentifier(pipe)] = nil }
            }
        }
    }
}

/// One host program and the framing Chrome uses to talk to it.
final class HostPipe: @unchecked Sendable {
    /// How long a host that has exited may leave its output open (a child of
    /// its own still holding it) before the connection ends anyway.
    static let exitGrace: TimeInterval = 1.5
    /// How long a host has, once asked to stop, before it is killed, as in Chrome.
    static let killGrace: TimeInterval = 2
    /// The most a host may send in one message, as in Chrome.
    static let frameCap = 1 << 20

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let lock = NSLock()
    private let writing = NSLock()
    var onMessage: ((Data) -> Void)?
    var onExit: (() -> Void)?
    private var waiters: [(id: Int, continuation: CheckedContinuation<Data, Error>)] = []
    private var nextWaiter = 0
    private var stopped = false
    private var outputClosed = false
    private var finished = false
    private var ending = false

    private static var exited: Error { ExtensionNative.Refused(why: "Native host has exited.") }

    init(program: URL, origin: String) {
        process.executableURL = program
        process.arguments = [origin]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A host already gone — refused to run or killed as it started — would
        // take the browser with it: writing to its closed pipe raises SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.lock.lock()
                self.outputClosed = true
                self.lock.unlock()
                self.finish()
                self.end()
                return
            }
            self.take(chunk)
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let now = self.stopped || self.outputClosed
            self.lock.unlock()
            if now {
                self.finish()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.exitGrace) {
                    self.finish()
                    self.end()
                }
            }
        }
        try process.run()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { end() } else { finish() }
    }

    func write(_ json: Data) throws {
        guard json.count <= Self.frameCap else {
            throw ExtensionNative.Refused(why: "Message too long for a native host")
        }
        var length = UInt32(json.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        writing.lock()
        defer { writing.unlock() }
        guard !stopped, !finished else { throw Self.exited }
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    func readOne() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            if wait(continuation) == nil { continuation.resume(throwing: Self.exited) }
        }
    }

    func request(_ message: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            guard let id = wait(continuation) else {
                return continuation.resume(throwing: Self.exited)
            }
            do {
                try write(message)
            } catch {
                lock.lock()
                let index = waiters.firstIndex { $0.id == id }
                if index != nil { waiters.remove(at: index!) }
                lock.unlock()
                if index != nil { continuation.resume(throwing: error) }
            }
        }
    }

    private func wait(_ continuation: CheckedContinuation<Data, Error>) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        nextWaiter += 1
        waiters.append((nextWaiter, continuation))
        return nextWaiter
    }

    private func take(_ chunk: Data) {
        lock.lock()
        guard !finished else { return lock.unlock() }
        buffer.append(chunk)
        var messages: [Data] = []
        var overlong = false
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            })
            if length > Self.frameCap {
                overlong = true
                buffer = Data()
                break
            }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            messages.append(body)
        }
        if overlong { finish() }
        var waiting = waiters
        waiters = []
        lock.unlock()

        for message in messages {
            if waiting.isEmpty {
                onMessage?(message)
            } else {
                let first = waiting.removeFirst()
                first.continuation.resume(returning: message)
            }
        }
        for waiter in waiting {
            waiter.continuation.resume(throwing: Self.exited)
        }
    }

    private func finish() {
        lock.lock()
        guard !finished else { return lock.unlock() }
        finished = true
        let waiting = waiters
        waiters = []
        lock.unlock()
        waiting.forEach { $0.continuation.resume(throwing: Self.exited) }
    }

    private func end() {
        lock.lock()
        guard !ending else { return lock.unlock() }
        ending = true
        lock.unlock()
        onExit?()
        if process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) {
                if self.process.isRunning { self.process.terminate() }
            }
        }
    }
}
