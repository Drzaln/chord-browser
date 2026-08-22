import Foundation

/// Downloads a release zip, extracts it, and swaps the bundled `.app` into the
/// applications directory. Foundation-only: extraction shells out to `ditto`,
/// which preserves bundle metadata, symlinks, and permissions that ZIP's own
/// unarchive APIs get wrong.
public struct AppInstaller: Sendable {
    public struct InstallError: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public let applicationsDirectory: URL
    public let supportDirectory: URL

    public init(
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        supportDirectory: URL? = nil
    ) {
        self.applicationsDirectory = applicationsDirectory
        if let supportDirectory {
            self.supportDirectory = supportDirectory
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support")
            self.supportDirectory = base.appendingPathComponent("Chord/Updates", isDirectory: true)
        }
    }

    /// Fetches `asset`, unzips it, finds the bundled `.app`, and swaps it into
    /// the applications directory. Returns the installed app URL.
    public func install(
        release: GitHubRelease,
        asset: GitHubRelease.Asset,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let fileManager = FileManager.default
        let staging = supportDirectory.appendingPathComponent(release.tagName, isDirectory: true)
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        let zipURL = staging.appendingPathComponent(asset.name)
        try await download(asset.downloadURL, to: zipURL, progress: progress)

        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        try extract(zip: zipURL, to: extracted)

        guard let bundledApp = findAppBundle(in: extracted) else {
            throw InstallError(message: "No .app bundle found inside \(asset.name).")
        }

        let destination = applicationsDirectory.appendingPathComponent(bundledApp.lastPathComponent)
        try swap(intoPlace: destination, from: bundledApp)
        stripQuarantine(at: destination)
        try? fileManager.removeItem(at: staging)
        return destination
    }

    // MARK: - Download

    private func download(
        _ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallError(
                message: "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."
            )
        }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: tempURL, to: destination)
    }

    // MARK: - Extraction

    private func extract(zip: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        try run(process)
    }

    // MARK: - Install

    private func swap(intoPlace destination: URL, from source: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            // Cross-volume fallback (rare: staging usually shares the volume).
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private func findAppBundle(in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "app" else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            if isDirectory { return url }
        }
        return nil
    }

    private func stripQuarantine(at url: URL) {
        // `xattr` is the supported way to clear the quarantine attribute. The
        // user explicitly asked for this update, and stripping quarantine keeps
        // Gatekeeper from flagging the just-downloaded bundle.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? run(process)
    }

    private func run(_ process: Process) throws {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError(
                message: "\(process.executableURL?.lastPathComponent ?? "tool") failed "
                    + "(exit \(process.terminationStatus))."
            )
        }
    }
}

/// Reports download progress as a fraction (0...1) on a background queue; the
/// caller is responsible for hopping to the main actor.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        progress(min(max(fraction, 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}