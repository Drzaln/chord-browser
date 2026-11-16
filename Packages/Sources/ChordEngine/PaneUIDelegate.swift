import Foundation
import WebKit

/// A pane's `uiDelegate`: the coordinator, except that it owns up to WebKit's
/// display-capture question only while the pane shows an extension's page.
///
/// WebKit asks `respondsToSelector:` for
/// `_webView:requestDisplayCapturePermissionForOrigin:…` on every
/// `getDisplayMedia` call. A delegate without the method gets the Mac's full
/// picker, screens and windows both. A delegate with it has to choose one:
/// its answers are deny, screen or window, and there is no "let the user
/// choose". So the coordinator answering for every page left websites such as
/// Google Meet with entire screens only. An extension's page still needs the
/// method, to be refused unless Chord's own capture call is in flight.
///
/// One per web view, since `respondsToSelector:` is not told which view is
/// asking. Everything else forwards to the coordinator.
@MainActor
final class PaneUIDelegate: NSObject {
    static let displayCaptureSelector = NSSelectorFromString(
        "_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:"
    )

    private let coordinator: NavigationCoordinator
    private weak var webView: WKWebView?

    init(coordinator: NavigationCoordinator, webView: WKWebView) {
        self.coordinator = coordinator
        self.webView = webView
        super.init()
    }

    /// Whether a page at this address has its display capture answered by
    /// Chord rather than by WebKit's picker.
    nonisolated static func answersDisplayCapture(for url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "chrome-extension" || scheme == "webkit-extension"
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        MainActor.assumeIsolated {
            if selector == Self.displayCaptureSelector {
                return Self.answersDisplayCapture(for: webView?.url)
            }
            return coordinator.responds(to: selector)
        }
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        MainActor.assumeIsolated { coordinator }
    }
}

/// Every method is the coordinator's, reached through `forwardingTarget`.
extension PaneUIDelegate: WKUIDelegate {}
