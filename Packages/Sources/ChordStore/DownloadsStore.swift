import ChordCore
import ChordEngine
import Foundation
import Observation

/// Observable list of downloads for the UI (M4).
///
/// Separate from `TabStore` on purpose: a progress tick arrives many times a
/// second, and if it lived on the tab store every tick would invalidate the
/// sidebar and the Space switcher along with it (6.4). This is the same reason
/// load progress lives in `PaneRuntime`.
@MainActor
@Observable
public final class DownloadsStore {
    public private(set) var downloads: [DownloadItem] = []

    @ObservationIgnored private let coordinator: DownloadCoordinator
    /// Ids seen so far, so a download that newly appears can be told from a
    /// progress tick on one already known.
    @ObservationIgnored private var knownIDs: Set<UUID> = []

    /// Called once when a download *starts*. Used to surface a clue when the
    /// sidebar (and with it the Downloads button) is out of the way.
    @ObservationIgnored public var onStarted: ((DownloadItem) -> Void)?

    public init(coordinator: DownloadCoordinator) {
        self.coordinator = coordinator
        coordinator.observer = self
        downloads = coordinator.downloadItems
        knownIDs = Set(downloads.map(\.id))
    }

    public var activeCount: Int { downloads.filter(\.isActive).count }

    /// Whether the UI should show the downloads affordance at all.
    public var hasDownloads: Bool { !downloads.isEmpty }

    public func cancel(_ id: UUID) { coordinator.cancel(id) }
    public func clear(_ id: UUID) { coordinator.clear(id) }
}

extension DownloadsStore: DownloadObserver {
    public func downloadsDidChange(_ downloads: [DownloadItem]) {
        self.downloads = downloads
        for item in downloads where !knownIDs.contains(item.id) {
            knownIDs.insert(item.id)
            if item.isActive { onStarted?(item) }
        }
    }
}
