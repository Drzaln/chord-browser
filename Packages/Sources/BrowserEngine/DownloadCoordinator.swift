import BrowserCore
import Foundation
import WebKit

@MainActor
public protocol DownloadObserver: AnyObject {
    /// The full list, whenever anything changes. Small and bounded, so the UI
    /// does not need diffing.
    func downloadsDidChange(_ downloads: [DownloadItem])
}

/// Owns `WKDownload` and its delegate conformance (M4).
///
/// Everything WebKit-shaped stops here: callers see `DownloadItem` only.
///
/// Only delegate methods that exist on macOS are implemented. In particular
/// `decidePlaceholderPolicy`, `didReceivePlaceholderURL`, and
/// `didReceiveFinalURL` are **iOS and visionOS only** — they are not part of the
/// macOS protocol and adding them would do nothing.
@MainActor
public final class DownloadCoordinator: NSObject {
    public weak var observer: (any DownloadObserver)?

    /// Where finished files land. Writing here needs
    /// `com.apple.security.files.downloads.read-write`; without that
    /// entitlement every destination callback fails and downloads never start.
    private let directory: URL
    private let now: () -> Date

    private var items: [UUID: DownloadItem] = [:]
    /// Insertion order, newest first, so the UI does not re-sort a dictionary.
    private var order: [UUID] = []

    /// `WKDownload` is matched back to our item by identity. It is retained by
    /// WebKit for the life of the transfer; we hold it to support cancellation.
    private var downloads: [UUID: WKDownload] = [:]
    private var identities: [ObjectIdentifier: UUID] = [:]
    /// Progress is observed rather than polled — `WKDownload` conforms to
    /// `NSProgressReporting`, so there is no byte counting to do by hand.
    private var progressObservations: [UUID: NSKeyValueObservation] = [:]

    /// The user's **real** `~/Downloads`.
    ///
    /// `FileManager.urls(for: .downloadsDirectory…)` looks right and is wrong
    /// under the sandbox: it returns the *container's* Downloads,
    /// `~/Library/Containers/com.rizal.browser/Data/Downloads`, so every
    /// downloaded file landed somewhere Finder's Downloads never shows. The
    /// entitlement (`files.downloads.read-write`) grants the real folder; it is
    /// the *path lookup* that the sandbox rewrites, not the permission.
    ///
    /// `getpwuid` reads the password database, which is not rewritten, so it
    /// gives the true home directory in both a sandboxed app and a plain test
    /// process. Falls back to the old lookup if that ever fails — a wrong
    /// directory is better than no downloads at all.
    public nonisolated static func userDownloadsDirectory() -> URL {
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            let path = String(cString: home)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
                    .appending(path: "Downloads", directoryHint: .isDirectory)
            }
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    public init(
        directory: URL = DownloadCoordinator.userDownloadsDirectory(),
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.now = now
        super.init()
    }

    public var downloadItems: [DownloadItem] { order.compactMap { items[$0] } }

    /// Adopts a download WebKit has just handed us. The delegate must be set
    /// here or no progress is ever reported.
    func adopt(_ download: WKDownload, suggestedURL: URL?) {
        let id = UUID()
        let url = suggestedURL ?? download.originalRequest?.url
            ?? URL(string: "about:blank")!

        items[id] = DownloadItem(
            id: id,
            url: url,
            filename: url.lastPathComponent,
            startedAt: now()
        )
        order.insert(id, at: 0)
        downloads[id] = download
        identities[ObjectIdentifier(download)] = id

        download.delegate = self
        observeProgress(of: download, id: id)
        publish()
    }

    private func observeProgress(of download: WKDownload, id: UUID) {
        progressObservations[id] = download.progress.observe(
            \.completedUnitCount, options: [.new]
        ) { [weak self] progress, _ in
            // KVO on NSProgress arrives off the main thread.
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor [weak self] in
                self?.updateBytes(id: id, received: received, total: total)
            }
        }
    }

    private func updateBytes(id: UUID, received: Int64, total: Int64) {
        guard var item = items[id], item.isActive else { return }
        item.bytesReceived = received
        item.bytesExpected = total > 0 ? total : -1
        items[id] = item
        publish()
    }

    public func cancel(_ id: UUID) {
        guard let download = downloads[id] else { return }
        download.cancel { _ in }
        finish(id: id, state: .cancelled)
    }

    /// Removes a finished row from the list. Never touches the file on disk.
    public func clear(_ id: UUID) {
        guard items[id]?.isActive == false else { return }
        items[id] = nil
        order.removeAll { $0 == id }
        publish()
    }

    private func finish(id: UUID, state: DownloadItem.State) {
        progressObservations[id]?.invalidate()
        progressObservations[id] = nil
        if let download = downloads[id] {
            identities[ObjectIdentifier(download)] = nil
        }
        downloads[id] = nil

        guard var item = items[id] else { return }
        item.state = state
        items[id] = item
        publish()
    }

    private func id(for download: WKDownload) -> UUID? {
        identities[ObjectIdentifier(download)]
    }

    private func publish() {
        observer?.downloadsDidChange(downloadItems)
    }
}

extension DownloadCoordinator: WKDownloadDelegate {

    /// Required. WebKit needs a URL that does not exist, inside a directory that
    /// does; returning nil cancels the download.
    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        guard let id = id(for: download) else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        } catch {
            // The overwhelmingly likely cause is a missing
            // files.downloads.read-write entitlement, which fails here rather
            // than anywhere more obvious.
            Log.engine.error("download directory unavailable: \(String(describing: error))")
            finish(id: id, state: .failed(message: "Downloads folder unavailable", canResume: false))
            return nil
        }

        let destination = DownloadNaming.uniqueURL(
            for: suggestedFilename,
            in: directory,
            exists: { FileManager.default.fileExists(atPath: $0.path) }
        )

        if var item = items[id] {
            item.destination = destination
            item.filename = destination.lastPathComponent
            if response.expectedContentLength > 0 {
                item.bytesExpected = response.expectedContentLength
            }
            items[id] = item
            publish()
        }

        return destination
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let id = id(for: download) else { return }
        recordFinalSize(of: download, id: id)
        finish(id: id, state: .finished)
    }

    /// Writes the true byte count onto the item before it is marked finished.
    ///
    /// Progress alone is not enough: `updateBytes` ignores anything arriving
    /// once the item is no longer active, and a download that completes inside
    /// a single chunk may never deliver a KVO tick at all — so the row said
    /// "Completed — Zero kB" for a file that was plainly on disk. The file
    /// itself is the ground truth and is consulted when the counter is empty.
    private func recordFinalSize(of download: WKDownload, id: UUID) {
        guard var item = items[id] else { return }

        let counted = download.progress.completedUnitCount
        if counted > 0 {
            item.bytesReceived = counted
        } else if let destination = item.destination,
            let size = try? FileManager.default.attributesOfItem(
                atPath: destination.path
            )[.size] as? NSNumber
        {
            item.bytesReceived = size.int64Value
        }

        // A finished download's size is known, whatever the server said up
        // front, so the row can stop saying "of unknown".
        item.bytesExpected = item.bytesReceived
        items[id] = item
    }

    public func download(
        _ download: WKDownload,
        didFailWithError error: any Error,
        resumeData: Data?
    ) {
        guard let id = id(for: download) else { return }
        Log.engine.error("download failed: \(String(describing: error))")
        finish(
            id: id,
            state: .failed(
                message: (error as NSError).localizedDescription,
                canResume: resumeData != nil
            )
        )
    }
}
