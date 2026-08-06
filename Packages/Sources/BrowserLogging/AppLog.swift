import Foundation
import os

/// One logging sink for the whole app (BROWSER_SPEC 3.7: one subsystem, a
/// category per package, no `print`).
///
/// Every line goes to **both** sinks:
///
/// 1. `os.Logger` — keeps Console/Instruments readable on machines where the
///    unified log is retrievable. The whole line is logged at `.public`, so
///    nothing is redacted there.
/// 2. A rotating file — because on this machine `log show` / `log stream` are
///    unreadable, the file is the only place debugging can actually be read
///    back from. The file mirror is off until `install(fileURL:)` is called
///    (the app does that at launch).
///
/// Call sites keep the historical shape — `Log.store.error("…")` — via each
/// package's own `enum Log`:
///
///     enum Log { static let store = AppLog.category("store") }
///
/// The `\(x, privacy: .public)` qualifiers are intentionally gone from call
/// sites: they only compile in os-logging contexts, and the file mirror wants
/// the raw text anyway.
public enum AppLog {

    /// A category handle, value-typed so `enum Log` statics stay cheap and
    /// `Sendable`. The `name` is deliberately internal: categories are created
    /// only through `AppLog.category(_:)`.
    public struct Category: Sendable, Equatable {
        let name: String

        public func debug(_ message: String) { AppLog.write(level: .debug, category: name, message) }
        public func info(_ message: String) { AppLog.write(level: .info, category: name, message) }
        public func notice(_ message: String) { AppLog.write(level: .default, category: name, message) }
        public func error(_ message: String) { AppLog.write(level: .error, category: name, message) }
        public func fault(_ message: String) { AppLog.write(level: .fault, category: name, message) }
    }

    public static func category(_ name: String) -> Category { Category(name: name) }

    /// Enables the rotating file mirror, or disables it with `nil` (the default
    /// state — the `os.Logger` side always works).
    ///
    /// Called once at launch by `AppEnvironment.live()` with
    /// `Application Support/<app>/Logs/browser.log`. The file rotates when it
    /// passes `capBytes` (5 MB default): the current file is renamed to
    /// `browser.log.1` (overwriting) and a fresh one is started.
    public static func install(fileURL: URL?, capBytes: UInt64 = AppLog.defaultCapBytes) {
        FileSink.shared.install(fileURL: fileURL, capBytes: capBytes)
    }

    /// Where the mirror writes, or `nil` when it is off. Useful for the user to
    /// find the log.
    public static var fileURL: URL? { FileSink.shared.currentFileURL }

    static let subsystem = "com.rizal.browser"
    public static let defaultCapBytes: UInt64 = 5 * 1024 * 1024

    // MARK: - The write path

    /// The single write path. Nonisolated and allocation-light so it is safe to
    /// call from any thread (WebKit callbacks, GRDB, UI).
    static func write(level: OSLogType, category: String, _ message: String) {
        Logger(subsystem: subsystem, category: category)
            .log(level: level, "\(message, privacy: .public)")
        FileSink.shared.append(entry: format(level: level, category: category, message: message))
    }

    private static func format(level: OSLogType, category: String, message: String) -> String {
        let levelName: String
        switch level {
        case .fault: levelName = "fault"
        case .error: levelName = "error"
        case .default: levelName = "notice"
        case .info: levelName = "info"
        default: levelName = "debug"
        }
        // One entry = one line, so embedded newlines are escaped for greppability.
        let flat = message.replacingOccurrences(of: "\n", with: "\\n")
        return "\(Date.now.ISO8601Format()) [\(category)] \(levelName): \(flat)"
    }
}

/// The rotating-file half of `AppLog`. All state is confined to `queue`, which
/// is what makes `@unchecked Sendable` honest. Failures never propagate: a
/// write error drops the file mirror, and the `os.Logger` side keeps working.
final class FileSink: @unchecked Sendable {
    static let shared = FileSink()

    private let queue = DispatchQueue(label: "com.rizal.browser.log", qos: .utility)
    private var fileURL: URL?
    private var capBytes: UInt64 = 0
    private var handle: FileHandle?
    private var bytes: UInt64 = 0

    private init() {}

    var currentFileURL: URL? {
        queue.sync { fileURL }
    }

    func install(fileURL: URL?, capBytes: UInt64) {
        queue.sync {
            self.fileURL = fileURL
            self.capBytes = capBytes
            handle = nil
            bytes = 0
        }
    }

    func append(entry: String) {
        queue.async { [weak self] in
            self?.appendOnQueue(entry)
        }
    }

    /// Drains the queue so tests can assert on the file. Internal, test-only.
    func flushForTesting() {
        queue.sync {}
    }

    private func appendOnQueue(_ entry: String) {
        guard let url = fileURL, capBytes > 0 else { return }
        do {
            if handle == nil {
                try open(url)
            }
            guard let handle else { return }
            let data = Data((entry + "\n").utf8)
            try handle.write(contentsOf: data)
            bytes += UInt64(data.count)
            if bytes > capBytes {
                try rotate(url)
            }
        } catch {
            handle = nil
        }
    }

    private func open(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let newHandle = try FileHandle(forWritingTo: url)
        try newHandle.seekToEnd()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        bytes = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        handle = newHandle
    }

    private func rotate(_ url: URL) throws {
        handle = nil
        let backup = url.appendingPathExtension("1")
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: url, to: backup)
        }
        bytes = 0
        try open(url)
    }
}
