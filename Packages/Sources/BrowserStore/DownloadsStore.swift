import BrowserCore
import BrowserEngine
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

    public init(coordinator: DownloadCoordinator) {
        self.coordinator = coordinator
        coordinator.observer = self
        downloads = coordinator.downloadItems
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
    }
}
