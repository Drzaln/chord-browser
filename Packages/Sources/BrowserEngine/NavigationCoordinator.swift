import AppKit
import BrowserCore
import Foundation
import WebKit

/// Owns the WebKit delegate conformances so `WebKitEngine` stays readable.
///
/// Holds the engine weakly: `WKWebView` keeps its delegates weak, but this
/// object is retained by the engine, and a strong back-reference would close
/// the cycle.
@MainActor
final class NavigationCoordinator: NSObject {
    weak var engine: WebKitEngine?

    init(engine: WebKitEngine) {
        self.engine = engine
        super.init()
    }

    private func paneID(for webView: WKWebView) -> UUID? {
        engine?.paneID(for: webView)
    }
}

extension NavigationCoordinator: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let paneID = paneID(for: webView) else { return }
        engine?.publishSnapshot(for: paneID)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let paneID = paneID(for: webView) else { return }
        engine?.publishSnapshot(for: paneID)
        engine?.fetchFavicon(for: paneID)
        // A reload built a fresh JS context, so re-assert mute if this pane is
        // muted (non-spec: user-requested).
        engine?.reapplyMute(paneID: paneID)
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        report(error, webView: webView)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        report(error, webView: webView)
    }

    private func report(_ error: Error, webView: WKWebView) {
        // A cancelled navigation is the normal result of the user clicking a new
        // link mid-load, not a failure worth surfacing.
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }

        Log.engine.error("\(EngineError.navigationFailed(url: webView.url, underlying: error))")
        if let paneID = paneID(for: webView) {
            engine?.publishSnapshot(for: paneID)
        }
    }

    /// Turns a response the web view cannot display into a download.
    ///
    /// Without this, clicking a `.zip` or `.dmg` link does nothing at all —
    /// WebKit will not start a download on its own.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        // `canShowMIMEType` is false for anything WebKit has no renderer for,
        // which is exactly the set that should download instead.
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    /// After returning `.download` from the response policy above. Setting the
    /// delegate here is required — progress is never reported otherwise.
    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        engine?.adoptDownload(download, suggestedURL: navigationResponse.response.url)
    }

    /// After returning `.download` from the *action* policy — a link marked
    /// `download`, for instance.
    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        engine?.adoptDownload(download, suggestedURL: navigationAction.request.url)
    }

    /// Content processes die routinely. Without this the app looks hung — the
    /// view goes blank and never recovers. Required from day one (3.4).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let paneID = paneID(for: webView) else { return }
        Log.engine.error("content process terminated for pane \(paneID, privacy: .public)")
        engine?.recoverFromTermination(paneID: paneID)
    }
}

extension NavigationCoordinator: WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let webView = message.webView, let paneID = paneID(for: webView) else { return }

        switch message.name {
        case MediaActivityMonitor.messageName:
            guard let playing = MediaActivityMonitor.isPlayingAudio(from: message.body) else { return }
            engine?.setPlayingAudio(playing, for: paneID)
        case ScreenShareMonitor.messageName:
            guard let sharing = ScreenShareMonitor.isScreenSharing(from: message.body) else { return }
            engine?.setScreenSharing(sharing, for: paneID)
        case ContextLinkMonitor.messageName:
            engine?.setContextLinkURL(ContextLinkMonitor.linkURL(from: message.body), for: paneID)
        case PeekLinkMonitor.messageName:
            // Only the frontmost pane's hovers should drive the shared preview.
            engine?.delegate?.paneRequestedPeek(url: PeekLinkMonitor.linkURL(from: message.body))
        case NotificationBridge.showMessageName:
            guard let request = NotificationBridge.request(from: message.body) else { return }
            engine?.delegate?.paneRequestedNotification(request, fromPane: paneID)
        default:
            break
        }
    }
}

extension NavigationCoordinator: WKScriptMessageHandlerWithReply {

    /// `Notification.requestPermission()` — the one channel that needs a value
    /// back, so it is a with-reply handler. Resolves to the web-spec strings.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard message.name == NotificationBridge.permissionMessageName else {
            replyHandler(nil, "unexpected message")
            return
        }
        Task { @MainActor in
            let granted = await engine?.delegate?.paneRequestedNotificationPermission() ?? false
            replyHandler(granted ? "granted" : "denied", nil)
        }
    }
}

extension NavigationCoordinator: WKUIDelegate {

    /// `target="_blank"` and `window.open`. Returning nil tells WebKit we handled
    /// it ourselves; the store opens a real tab.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            engine?.delegate?.paneRequestedNewTab(
                url: url, fromPane: paneID(for: webView)
            )
        }
        return nil
    }

    /// Camera and microphone for `getUserMedia` — Google Meet, Slack huddles, etc.
    ///
    /// Per-origin, ask-once: the store consults its remembered decision for this
    /// site and prompts the user the first time (normal browser behaviour),
    /// rather than the old blanket grant that let every site capture unasked.
    /// A grant here still passes to the OS, which shows its own camera/microphone
    /// TCC prompt the first time for the app as a whole (backed by the sandbox
    /// `device.camera`/`device.microphone` entitlements and the `NS*UsageDescription`
    /// strings in Info.plist); denying it there denies the site.
    ///
    /// Screen sharing (`getDisplayMedia`) is deliberately absent: `WKMediaCaptureType`
    /// has only camera and microphone, and public WKWebView exposes no display-
    /// capture permission hook, so "Present now" in Meet cannot be supported
    /// through the public SDK (verified against WKUIDelegate.h). Not faked here.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let devices: [MediaDevice]
        switch type {
        case .camera: devices = [.camera]
        case .microphone: devices = [.microphone]
        case .cameraAndMicrophone: devices = [.camera, .microphone]
        @unknown default: devices = [.camera, .microphone]
        }
        let host = origin.host
        let originString = host.isEmpty ? origin.`protocol` : "\(origin.`protocol`)://\(host)"
        let request = MediaPermissionRequest(
            origin: originString,
            host: host,
            devices: devices,
            paneID: paneID(for: webView)
        )
        Task { @MainActor in
            let granted = await engine?.delegate?.paneRequestedMediaCapture(request) ?? false
            decisionHandler(granted ? .grant : .deny)
        }
    }
}
