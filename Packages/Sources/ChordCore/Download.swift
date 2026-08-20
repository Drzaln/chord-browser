import Foundation

/// A download, as everything outside the engine sees it (M4).
///
/// No WebKit type appears here: `WKDownload` and its `NSProgress` stay inside
/// `ChordEngine`, and this is the flattened snapshot the UI renders (7.1).
public struct DownloadItem: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case inProgress
        case finished
        /// `resumeData` is kept so the download can be retried; WebKit only
        /// hands it over at the moment of failure.
        case failed(message: String, canResume: Bool)
        case cancelled
    }

    public let id: UUID
    public var url: URL
    public var filename: String
    /// Where the bytes are being written. Nil until a destination is decided.
    public var destination: URL?
    public var bytesReceived: Int64
    /// -1 when the server did not say. Do not render a determinate bar for it.
    public var bytesExpected: Int64
    public var state: State
    public var startedAt: Date

    public init(
        id: UUID = UUID(),
        url: URL,
        filename: String,
        destination: URL? = nil,
        bytesReceived: Int64 = 0,
        bytesExpected: Int64 = -1,
        state: State = .inProgress,
        startedAt: Date
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.destination = destination
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
        self.state = state
        self.startedAt = startedAt
    }

    /// 0...1, or nil when the total is unknown — which is common enough that
    /// callers must handle it rather than showing a bar stuck at zero.
    public var fractionCompleted: Double? {
        guard bytesExpected > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(bytesExpected))
    }

    public var isActive: Bool { state == .inProgress }
}

/// Picks a destination for a download without overwriting anything.
public enum DownloadNaming {
    /// Returns `name`, or `name-1`, `name-2`, ... if taken.
    ///
    /// WebKit requires a URL that does **not** already exist, in a directory
    /// that does, so resolving a collision here is not optional — handing back
    /// an existing path fails the download outright.
    public static func uniqueURL(
        for filename: String,
        in directory: URL,
        exists: (URL) -> Bool
    ) -> URL {
        let safe = sanitize(filename)
        let candidate = directory.appendingPathComponent(safe)
        guard exists(candidate) else { return candidate }

        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension

        for suffix in 1... {
            let name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            let next = directory.appendingPathComponent(name)
            if !exists(next) { return next }
        }
        // `for suffix in 1...` never terminates without returning.
        fatalError("unreachable: unique filename search cannot exhaust")
    }

    /// Web content controls the suggested filename, so it is not trusted.
    ///
    /// Taking the last path component discards directory traversal outright
    /// rather than trying to escape it — `../../etc/passwd` becomes `passwd`,
    /// which cannot leave the downloads directory however it is joined.
    static func sanitize(_ filename: String) -> String {
        let component = (filename as NSString).lastPathComponent
        var cleaned = component
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A leading dot would hide the file from the user who just asked for it.
        while cleaned.hasPrefix(".") { cleaned = String(cleaned.dropFirst()) }

        return cleaned.isEmpty ? "download" : cleaned
    }
}
