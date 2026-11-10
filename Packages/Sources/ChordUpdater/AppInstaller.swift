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
    /// What a download must be to be installed. Nil means "the app this
    /// process is running from", looked up when an install starts.
    public let expected: BundleIdentity?

    public init(
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        supportDirectory: URL? = nil,
        expected: BundleIdentity? = nil
    ) {
        self.applicationsDirectory = applicationsDirectory
        self.expected = expected
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

    /// Fetches `asset`, unzips it, finds the bundled `.app`, checks it is the
    /// update it claims to be, and swaps it into the applications directory.
    /// Returns the installed app URL.
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
        // A refused or failed download is not kept around.
        defer { try? fileManager.removeItem(at: staging) }

        let zipURL = staging.appendingPathComponent(asset.name)
        try await download(asset.downloadURL, to: zipURL, progress: progress)
        return try installDownloaded(zip: zipURL, release: release, staging: staging)
    }

    /// Everything after the download. Nothing in the applications directory is
    /// touched until the bundle has passed `BundleVerifier`.
    func installDownloaded(zip zipURL: URL, release: GitHubRelease, staging: URL) throws -> URL {
        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try extract(zip: zipURL, to: extracted)

        guard let bundledApp = findAppBundle(in: extracted) else {
            throw InstallError(message: "No .app bundle found inside \(zipURL.lastPathComponent).")
        }
        guard let expected = expected ?? BundleIdentity.running() else {
            throw InstallError(message: "Chord could not tell which app it is, so it did not install the update.")
        }
        do {
            try BundleVerifier.verify(bundledApp, expected: expected, version: release.version)
        } catch let failure as BundleVerifier.Failure {
            throw InstallError(message: "The update was not installed: \(failure.message)")
        }

        let destination = applicationsDirectory.appendingPathComponent(bundledApp.lastPathComponent)
        try swap(intoPlace: destination, from: bundledApp)
        stripQuarantine(at: destination)
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

    func swap(intoPlace destination: URL, from source: URL) throws {
        let fileManager = FileManager.default
        // The installed copy is moved aside, not deleted, until the new one is
        // in place: a failed swap must not leave the user with no app. Beside
        // the destination, so the move is a rename on the same volume.
        var previous: URL?
        if fileManager.fileExists(atPath: destination.path) {
            let aside = destination.deletingLastPathComponent().appendingPathComponent(
                ".\(destination.lastPathComponent).previous-\(UUID().uuidString.prefix(8))")
            try fileManager.moveItem(at: destination, to: aside)
            previous = aside
        }
        do {
            do {
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                // Cross-volume fallback (rare: staging usually shares the volume).
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: source, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: destination)
            if let previous { try? fileManager.moveItem(at: previous, to: destination) }
            throw error
        }
        if let previous { try? fileManager.removeItem(at: previous) }
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