import ChordCore
import ChordEngine
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
    /// When this pane's sleep timer fires, if one is armed (non-spec:
    /// user-requested).
    public var sleepTimerDeadline: Date?
    /// Whether the pane is screen-sharing (non-spec: user-requested). Drives the
    /// "sharing this window" banner; see `ScreenShareMonitor`.
    public var isScreenSharing: Bool = false
    /// The login fields this page is showing, once it has reported (V3 of the
    /// password vault). Nil means "not looked yet", which is not the same as
    /// "no login here" — the fill affordance must not appear on either, but only
    /// the second is an answer.
    public var loginForm: LoginFormAnalysis?
    /// Saved credentials that could fill this page (V6), recomputed by the store
    /// whenever the page's login report or URL changes. Observable, so the fill
    /// button is a pure function of state rather than a view-side async lookup
    /// racing the page load.
    public var fillableCredentials: [Credential] = []

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
        sleepTimerDeadline = snapshot.sleepTimerDeadline
        isScreenSharing = snapshot.isScreenSharing
        loginForm = snapshot.loginForm
        // Not cleared here: the store recomputes it, and blanking it on every
        // progress tick would make the button flicker while a page loads.
    }
}
