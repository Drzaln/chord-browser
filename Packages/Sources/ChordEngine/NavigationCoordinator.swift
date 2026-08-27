import AppKit
import ChordCore
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

    /// Answers the page's shimmed `navigator.geolocation` position requests
    /// with real CoreLocation fixes (see `GeolocationBridge`).
    private let locationProvider = ChordLocationProvider()

    init(engine: WebKitEngine) {
        self.engine = engine
        super.init()
    }

    private func paneID(for webView: WKWebView) -> UUID? {
        engine?.paneID(for: webView)
    }

    /// A plain left-click on a link: no ⌘/⌥/⌃/⇧ modifiers, not the middle
    /// button, GET, http(s). The shared gate for the two paths a link click can
    /// take — same-page navigation (`decidePolicyFor`) and `target="_blank"` /
    /// `window.open` (`createWebViewWith`). Only such a click may be lifted
    /// into a Peek; everything else keeps its ordinary meaning.
    ///
    /// `buttonNumber` is not required to be 0: when Gmail's JS synthesizes the
    /// click, WebKit reports the left click as `buttonNumber == 1` (seen in the
    /// field: a GitHub link in a Gmail email, type `.linkActivated`, mods 0,
    /// button 1). The requirement is only that it is not the middle button.
    private func isPlainLinkClick(_ action: WKNavigationAction) -> Bool {
        action.navigationType == .linkActivated
            && action.buttonNumber != 2
            && action.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            && action.request.httpMethod == "GET"
            && action.request.httpBody == nil
            && (action.request.url?.scheme == "http" || action.request.url?.scheme == "https")
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

    /// Stamps the right User-Agent on a main-frame navigation before it goes out
    /// (§9.6), then allows it.
    ///
    /// **Why a cancel-and-reload rather than just setting the property.**
    /// `customUserAgent` is read when the request is built, so a change made
    /// here arrives too late for *this* request — the page would load under the
    /// previous site's UA and only correct itself on the next navigation, which
    /// is exactly the confusing half-fix this feature exists to avoid. So when
    /// the UA actually changes, the navigation is cancelled and re-issued.
    ///
    /// Two guards keep that from being destructive:
    /// - it only re-issues **GET** requests in the **main frame**. Re-loading a
    ///   POST would silently drop the body — a re-submitted form, a lost
    ///   comment — and no UA is worth that, so a non-GET keeps the new UA for
    ///   next time and proceeds.
    /// - `applyUserAgent` returns false when nothing changed, so the re-issued
    ///   request matches on the second pass and is allowed. There is no state to
    ///   get wrong and no way to loop.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        // A plain left-click on a link in a favourite/pinned tab is a Peek
        // (non-spec: user-requested): the store lifts the navigation into the
        // floating panel instead of letting the click move the protected page.
        // The store decides based on placement, so an ephemeral tab clicks
        // through exactly as before.
        if isPlainLinkClick(navigationAction),
            navigationAction.targetFrame?.isMainFrame == true,
            let url = navigationAction.request.url,
            let paneID = paneID(for: webView),
            engine?.delegate?.paneRequestedPeek(url: url, fromPane: paneID) == true
        {
            return .cancel
        }

        guard navigationAction.targetFrame?.isMainFrame == true,
            let engine,
            engine.applyUserAgent(to: webView, for: navigationAction.request.url)
        else { return .allow }

        guard navigationAction.request.httpMethod == "GET",
            navigationAction.request.httpBody == nil
        else { return .allow }

        let request = navigationAction.request
        webView.load(request)
        return .cancel
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
        // which is exactly the set that should download instead — unless the
        // pane is a Peek preview, which was opened by a *hover*. Downloading
        // there writes a file the user never asked for; cancelling just leaves
        // the preview blank, which is the honest outcome for something that
        // cannot be previewed.
        guard navigationResponse.canShowMIMEType else {
            return .download
        }
        return .allow
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
        Log.engine.error("content process terminated for pane \(paneID)")
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
        case PasswordFormMonitor.messageName:
            // One handler, two shapes: a submission carries values, a report
            // carries descriptors.
            if let submitted = PasswordFormMonitor.submission(from: message.body) {
                guard let url = webView.url,
                    let origin = CredentialOrigin.canonical(
                        for: url, policy: engine?.loginOriginPolicy ?? .strict
                    )
                else { return }
                engine?.delegate?.paneDidSubmitLogin(
                    origin: origin,
                    username: submitted.username,
                    password: submitted.password,
                    fromPane: paneID
                )
                return
            }
            guard let fields = PasswordFormMonitor.fields(from: message.body) else { return }
            engine?.setLoginForm(LoginFormClassifier.analyse(fields), for: paneID)
        case DRMDiagnosticsMonitor.messageName:
            // Two shapes, same as PasswordFormMonitor: a media error carries the
            // display string, an EME marker carries none.
            if let error = DRMDiagnosticsMonitor.mediaError(from: message.body) {
                engine?.setMediaError(error, for: paneID)
            } else if DRMDiagnosticsMonitor.isEME(message.body) {
                engine?.setEMEStarted(for: paneID)
            }
        case NotificationBridge.showMessageName:
            guard let request = NotificationBridge.request(from: message.body) else { return }
            engine?.delegate?.paneRequestedNotification(request, fromPane: paneID)
        default:
            break
        }
    }
}

extension NavigationCoordinator: WKScriptMessageHandlerWithReply {

    /// The shared origin-string builder used by the two with-reply channels.
    /// WebKit's `WKSecurityOrigin` gives protocol + host without the trailing
    /// slash, so "https://meet.google.com" is reconstructed by hand.
    private func originString(for securityOrigin: WKSecurityOrigin) -> String {
        let host = securityOrigin.host
        return host.isEmpty ? securityOrigin.`protocol` : "\(securityOrigin.`protocol`)://\(host)"
    }

    /// The with-reply channels (things a page needs a value back from):
    /// Web Notifications permission, and geolocation. Each op resolves to the
    /// web-spec strings the shim expects.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        let origin = message.frameInfo.securityOrigin
        let originString = originString(for: origin)
        let host = origin.host
        let requestPaneID = message.webView.flatMap { self.paneID(for: $0) }

        switch message.name {
        case NotificationBridge.permissionMessageName:
            let isRequest = NotificationBridge.isRequest(message.body)

            Task { @MainActor in
                guard let delegate = engine?.delegate else {
                    replyHandler("default", nil)
                    return
                }
                if isRequest {
                    let prompt = SitePermissionPrompt(
                        origin: originString, host: host, kinds: [.notification],
                        paneID: requestPaneID
                    )
                    let granted = await delegate.paneRequestedNotificationPermission(prompt)
                    replyHandler(granted ? "granted" : "denied", nil)
                } else {
                    let state = await delegate.paneNotificationPermissionState(
                        origin: originString, paneID: requestPaneID
                    )
                    replyHandler(state.jsValue, nil)
                }
            }

        case GeolocationBridge.messageName:
            guard let op = GeolocationBridge.op(from: message.body) else {
                replyHandler(nil, "unexpected message")
                return
            }

            switch op {
            case "query":
                Task { @MainActor in
                    let state =
                        await engine?.delegate?.paneGeolocationPermissionState(
                            origin: originString, paneID: requestPaneID
                        ) ?? .notDetermined
                    replyHandler(state.jsValue, nil)
                }
            case "request":
                Task { @MainActor in
                    let prompt = SitePermissionPrompt(
                        origin: originString, host: host, kinds: [.geolocation],
                        paneID: requestPaneID
                    )
                    let granted =
                        await engine?.delegate?.paneRequestedGeolocation(prompt) ?? false
                    replyHandler(granted ? "granted" : "denied", nil)
                }
            case "position":
                Task { @MainActor in
                    guard let coordinate = await locationProvider.currentPosition() else {
                        replyHandler(["error": "Position unavailable"], nil)
                        return
                    }
                    replyHandler(GeolocationBridge.positionPayload(coordinate), nil)
                }
            default:
                replyHandler(nil, "unknown op")
            }

        default:
            replyHandler(nil, "unexpected message")
        }
    }
}

extension NavigationCoordinator: WKUIDelegate {

    /// `target="_blank"` and `window.open`. Returning a real `WKWebView` — not
    /// `nil` plus a separate store-opened tab — keeps the page's `window.open()`
    /// reference alive (so OAuth login like Shopee's Google button can poll it
    /// for the result) and lets the page close itself with `window.close()`, the
    /// way OAuth popups tidy themselves up instead of lingering. The store hosts
    /// the popup as a tab, and `webViewDidClose` turns `window.close()` into
    /// "close that tab". (`window.opener` stays null in WKWebView; the
    /// `window.open()` return value is the mechanism OAuth flows rely on here.)
    ///
    /// A new-window request from a favourite/pinned tab is a Peek gesture, in
    /// both shapes it arrives in:
    /// - a plain left-click on a `target="_blank"` anchor → `.linkActivated`
    ///   (the `isPlainLinkClick` gate keeps modified clicks ordinary), or
    /// - Gmail's message-body links, which its JS opens via `window.open` →
    ///   `.other`, carrying no click/modifier information. The store's
    ///   placement check is the only gate there; the Braincup link inside a
    ///   Gmail email is exactly this path.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let plainClick = isPlainLinkClick(navigationAction)
        if plainClick || navigationAction.navigationType == .other,
            let url = navigationAction.request.url,
            let paneID = paneID(for: webView),
            engine?.delegate?.paneRequestedPeek(url: url, fromPane: paneID) == true
        {
            return nil
        }

        guard let engine else { return nil }
        return engine.makeAndAdoptPopup(
            openerConfiguration: configuration,
            url: navigationAction.request.url,
            fromPane: paneID(for: webView)
        )
    }

    /// A script-created window called `window.close()`. Only popups can do
    /// that, so this is how the Google tab from a Shopee login (and any other
    /// OAuth popup) tidies itself up once the flow is done.
    func webViewDidClose(_ webView: WKWebView) {
        guard let paneID = paneID(for: webView) else { return }
        engine?.delegate?.panePopupDidClose(paneID)
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
        let kinds: [SitePermissionKind]
        switch type {
        case .camera: kinds = [.camera]
        case .microphone: kinds = [.microphone]
        case .cameraAndMicrophone: kinds = [.camera, .microphone]
        @unknown default: kinds = [.camera, .microphone]
        }
        let host = origin.host
        let originString = host.isEmpty ? origin.`protocol` : "\(origin.`protocol`)://\(host)"
        let prompt = SitePermissionPrompt(
            origin: originString,
            host: host,
            kinds: kinds,
            paneID: paneID(for: webView)
        )
        Task { @MainActor in
            let granted = await engine?.delegate?.paneRequestedMediaCapture(prompt) ?? false
            decisionHandler(granted ? .grant : .deny)
        }
    }

    /// Geolocation for `navigator.geolocation` — Google Maps, Apple Maps web,
    /// etc.
    ///
    /// WebKit exposes no public geolocation permission hook in the SDK we ship
    /// against (verified against WKUIDelegate.h): the `requestGeolocationPermissionFor`
    /// delegate was private SPI for years and only promoted to public API in
    /// February 2026 (WebKit PR #58447, tracking WebKit bug 140208). The SDK's
    /// headers — public or private — carry neither, so this method is declared
    /// here with the SPI selector and WebKit calls it by name via the ObjC
    /// runtime.
    ///
    /// On macOS this is effectively a no-op: WebKit's built-in CoreLocation
    /// provider is iOS-only (`WKGeolocationProviderIOS`), so the UIProcess never
    /// routes a geolocation request to the delegate and a page's geolocation is
    /// silently denied (verified in the field: no call, no TCC prompt). Pages
    /// therefore get a shimmed `navigator.geolocation` (see `GeolocationBridge`)
    /// that answers from the host's `CLLocationManager`. This method is kept as
    /// belt-and-suspenders: on a WebKit build that does route geolocation here,
    /// the same per-origin ask-once path answers it.
    @objc func _webView(
        _ webView: WKWebView,
        requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let host = origin.host
        let originString = host.isEmpty ? origin.`protocol` : "\(origin.`protocol`)://\(host)"
        let prompt = SitePermissionPrompt(
            origin: originString,
            host: host,
            kinds: [.geolocation],
            paneID: paneID(for: webView)
        )
        Task { @MainActor in
            let granted = await engine?.delegate?.paneRequestedGeolocation(prompt) ?? false
            decisionHandler(granted ? .grant : .deny)
        }
    }
}
