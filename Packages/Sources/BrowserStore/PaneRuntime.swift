import BrowserEngine
import Foundation
import Observation

/// Volatile per-pane state that changes many times a second while a page loads.
///
/// Kept out of `TabStore` on purpose: `estimatedProgress` ticking must not
/// invalidate the sidebar or the tab list. Only the toolbar observes this (6.4).
@MainActor
@Observable
public final class PaneRuntime {
    public let paneID: UUID
    public var isLoading: Bool = false
    public var estimatedProgress: Double = 0
    public var canGoBack: Bool = false
    public var canGoForward: Bool = false
    public var currentURL: URL?
    /// Exempts the tab from the ephemeral sweep (4.3).
    public var isPlayingAudio: Bool = false
    /// Whether the user has muted this pane (non-spec: user-requested).
    public var isMuted: Bool = false
    /// Whether the pane is screen-sharing (non-spec: user-requested). Drives the
    /// "sharing this window" banner; see `ScreenShareMonitor`.
    public var isScreenSharing: Bool = false

    init(paneID: UUID) {
        self.paneID = paneID
    }

    func apply(_ snapshot: PaneSnapshot) {
        isLoading = snapshot.isLoading
        estimatedProgress = snapshot.estimatedProgress
        canGoBack = snapshot.canGoBack
        canGoForward = snapshot.canGoForward
        currentURL = snapshot.url
        isPlayingAudio = snapshot.isPlayingAudio
        isMuted = snapshot.isMuted
        isScreenSharing = snapshot.isScreenSharing
    }
}
