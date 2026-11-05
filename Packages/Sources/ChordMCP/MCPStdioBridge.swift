import Darwin
import Foundation

/// The `--mcp-stdio` helper: what an MCP client actually launches.
///
/// MCP clients speak stdio to a process they start; Chord is already running
/// and owns the browser. This copies bytes both ways between the two — client
/// stdin to Chord's socket, Chord's replies to client stdout — and holds no
/// MCP logic of its own, so there is nothing here to keep in step with the
/// server. Diagnostics go to stderr, which MCP clients show as server logs.
public enum MCPStdioBridge {
    /// Runs until either side hangs up. Returns the process exit status.
    public static func run(
        socketPath: String = MCPPaths.defaultSocketPath,
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        diagnostics: Int32 = STDERR_FILENO
    ) -> Int32 {
        signal(SIGPIPE, SIG_IGN)

        let socket: Int32
        do {
            socket = try MCPSocket.connect(to: socketPath)
        } catch {
            let message = """
                chord-mcp: could not reach Chord at \(socketPath) (\(error)).
                Open Chord and turn on Settings → Agents → "Allow local agents (MCP)".

                """
            MCPSocket.writeAll(Data(message.utf8), to: diagnostics)
            return 1
        }

        let inputEnded = DispatchSemaphore(value: 0)
        let socketEnded = DispatchSemaphore(value: 0)
        let pump = { (from: Int32, to: Int32, ended: DispatchSemaphore, onEnd: @escaping @Sendable () -> Void) in
            let thread = Thread {
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = read(from, &chunk, chunk.count)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0,
                          MCPSocket.writeAll(Data(chunk[0..<count]), to: to)
                    else { break }
                }
                onEnd()
                ended.signal()
            }
            thread.start()
        }

        // Client closed stdin: tell Chord nothing more is coming, but let any
        // reply still in flight come back before the socket side ends.
        pump(input, socket, inputEnded) { shutdown(socket, SHUT_WR) }
        // Chord hung up (quit, or the user pressed Disconnect): done, whatever
        // stdin is doing.
        pump(socket, output, socketEnded) {}

        let ready = DispatchSemaphore(value: 0)
        Thread { inputEnded.wait(); ready.signal() }.start()
        Thread { socketEnded.wait(); socketEnded.signal(); ready.signal() }.start()
        ready.wait()
        if socketEnded.wait(timeout: .now()) == .timedOut {
            // stdin ended first; give in-flight replies a moment to drain.
            _ = socketEnded.wait(timeout: .now() + 10)
        }
        close(socket)
        return 0
    }
}

/// Where the socket lives. One place, so the server and the helper agree.
public enum MCPPaths {
    /// `~/Library/Application Support/Chord/MCP/chord.sock`.
    public static var defaultSocketPath: String {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return support.appending(path: "Chord/MCP/chord.sock").path(percentEncoded: false)
    }

    /// The argument that turns Chord's own executable into the helper.
    public static let stdioFlag = "--mcp-stdio"
}
