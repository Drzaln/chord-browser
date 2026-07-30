#if DEBUG
import BrowserCore
import Foundation

extension TabStore {
    /// Developer diagnostic (non-spec): the media codecs this engine's WebKit
    /// advertises for the window's active pane, via `MediaSource.isTypeSupported`
    /// — the same check streaming sites run to pick a rendition. `nil` when the
    /// window has no selected tab or its pane has no live view. Returns a plain
    /// label/flag pair so the app layer needs no engine import. Surfaced by the
    /// Cmd+Ctrl+P overlay; compiled out of release.
    public func activeCodecSupport(
        in window: WindowState
    ) async -> [(label: String, supported: Bool, hardware: Bool)]? {
        guard let paneID = selectedTab(in: window)?.focusedPaneID else { return nil }
        guard let probes = await engine.codecSupport(for: paneID) else { return nil }
        return probes.map { ($0.label, $0.isSupported, $0.isPowerEfficient) }
    }
}
#endif
