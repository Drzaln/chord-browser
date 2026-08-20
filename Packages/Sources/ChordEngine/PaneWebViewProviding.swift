import Foundation
import WebKit

/// Hands the extension host a pane's live `WKWebView` (M7, 7.3b).
///
/// This is the one place the WebKit boundary runs *outward* — Engine → the
/// extension host — rather than inward. The controller handoff in 7.1 could stay
/// opaque (`ExtensionControllerHandle`) because the host constructed it and the
/// engine only read it. Here it is reversed: `WKWebExtensionTab.webView(for:)`
/// must return the actual `WKWebView`, which the engine owns, so the host has to
/// read it out. An opaque wrapper cannot help — WebKit wants the real view.
///
/// So this protocol names `WKWebView`. It is kept **off the `WebEngine`
/// protocol** that Store and UI consume, and nothing in Store or UI references
/// it: `AppEnvironment` forwards it as an existential (`any PaneWebViewProviding`)
/// without ever naming `WKWebView`. It is an engine-layer↔extension-layer seam,
/// exactly the sharing ADR 011 allows between the two WebKit importers.
@MainActor
public protocol PaneWebViewProviding: AnyObject {
    /// The pane's live web view, or `nil` if the pane has no view right now
    /// (restore is lazy, and an evicted pane has none). An extension simply
    /// cannot reach a page that is not currently rendered — which is correct.
    func paneWebView(_ paneID: UUID) -> WKWebView?
}

extension WebKitEngine: PaneWebViewProviding {
    public func paneWebView(_ paneID: UUID) -> WKWebView? {
        pool.view(for: paneID)?.webView
    }
}
