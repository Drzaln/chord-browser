import AppKit
import Foundation
import WebKit

/// Screen recording for extensions — Loom, Awesome Screenshot and the like.
///
/// Chrome hands an extension a stream id from its own picker
/// (`desktopCapture.chooseDesktopMedia`) and the stream for it from
/// `getUserMedia`. WebKit has neither. What it has is `getDisplayMedia`, which
/// shows the Mac's own picker and refuses unless the call comes from a gesture
/// in a page that is on screen. Chord stands in between: an extension's page
/// asks through a channel that knows who is asking, the page is brought
/// forward, and WebKit's `getDisplayMedia` is called in that page itself,
/// which WebKit counts as a click. The Mac's picker follows every time — it is
/// the Mac, not Chord, that asks what to share. The stream stays in the page
/// and is handed over as the answer to the extension's `getUserMedia`.
///
/// Nothing here uses ScreenCaptureKit or looks at other windows: WebKit's
/// picker is the only way in, and it needs no Screen Recording permission.
/// Tab capture is not available on WebKit (ADR 012), so `tabCapture` is
/// refused by the shim rather than faked.
@MainActor
final class ExtensionCapture: NSObject, WKScriptMessageHandlerWithReply {
    /// The name an extension's page posts to (`webkit.messageHandlers`).
    static let channel = "chordCapture"
    /// The page symbol holding the saved `getDisplayMedia`, called natively.
    static let symbol = "chord.capture"
    /// Chrome's stream-id lifetime: one use, for one extension, within a minute.
    static let lifetime: TimeInterval = 60

    /// How a sender's Chrome id becomes the context that id belongs to. The
    /// host owns loaded contexts, so it supplies this.
    var context: ((String) -> WKWebExtensionContext?)?
    /// Brings the asking page on screen, for WebKit's focus requirement. The
    /// host wires this to the tab model so an extension page in a tab is
    /// selected and its window raised. Returns whether the page is visible.
    var bringForward: ((WKWebView) async -> Bool)?
    /// What extensions are recording changed (1mm.15): the host names them
    /// and passes them on, WebKit-free, for the recording pill.
    var onRecordingsChanged: (([Watched.State]) -> Void)?

    // MARK: - Tokens

    /// A stream id handed to an extension: good once, for a minute, for that
    /// extension only.
    private struct Grant {
        let extensionID: String
        let made: Date
    }

    private var grants: [String: Grant] = [:]

    /// A worker has no page to record in, so `chooseDesktopMedia` gives it an
    /// id now; a page of that extension redeems it through `getUserMedia`.
    /// Empty when the extension never asked for `desktopCapture`.
    func grant(for context: WKWebExtensionContext) -> String {
        guard Self.declares(context) else { return "" }
        return issue(for: context.uniqueIdentifier)
    }

    /// Internal seam for tests: the same rules `grant(for:)` and `consume`
    /// use, without a page or a picker.
    func issue(for identifier: String, now: Date = Date()) -> String {
        grants = grants.filter { now.timeIntervalSince($0.value.made) < Self.lifetime }
        let token = Self.token()
        grants[token] = Grant(extensionID: identifier, made: now)
        return token
    }

    /// Redeems a token once. An expired or foreign token is refused and
    /// removed, as Chrome does with a stream id minted for someone else.
    func take(_ token: String, for identifier: String, now: Date = Date()) -> Bool {
        guard let grant = grants.removeValue(forKey: token) else { return false }
        return grant.extensionID == identifier
            && now.timeIntervalSince(grant.made) < Self.lifetime
    }

    /// `desktopCapture` is a Chrome permission WebKit does not model, so the
    /// manifest itself is the gate — required or optional.
    static func declares(_ context: WKWebExtensionContext) -> Bool {
        let manifest = context.webExtension.manifest
        let required = manifest["permissions"] as? [Any] ?? []
        let optional = manifest["optional_permissions"] as? [Any] ?? []
        return (required + optional).contains { ($0 as? String) == "desktopCapture" }
    }

    private static func token() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// An extension went away: its unused ids go with it.
    func purge(_ identifier: String) {
        stop(identifier)
        grants = grants.filter { $0.value.extensionID != identifier }
    }

    // MARK: - The channel

    func attach(_ controller: WKUserContentController?) {
        guard let controller, !attached.contains(controller) else { return }
        attached.add(controller)
        controller.addScriptMessageHandler(
            self, contentWorld: .page, name: Self.channel
        )
    }

    /// Which controllers this handler is on. Weak, and checked on attach:
    /// WebKit throws, uncatchably, if one name is added twice.
    private let attached = NSHashTable<WKUserContentController>.weakObjects()

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let op = body["op"] as? String
        else {
            replyHandler(nil, "Not a request")
            return
        }
        // Only the top of one of an extension's own pages, in a view of that
        // extension's: not a site framed in it, not its page framed in a
        // site, not another extension.
        guard let (context, web) = sender(of: message) else {
            replyHandler(["error": "NotAllowedError", "message": "Not allowed here"], nil)
            return
        }
        // The microphone or camera, from an offscreen document: an offscreen
        // page not made to capture has no window to ask from and is refused.
        if op == "lend" {
            if let reasons = ExtensionOffscreen.reasons(of: web),
               reasons.isDisjoint(with: ["USER_MEDIA", "DISPLAY_MEDIA"]) {
                return replyHandler([
                    "error": "NotAllowedError",
                    "message": "This offscreen document wasn't made to record",
                ], nil)
            }
            return replyHandler(["ok": true], nil)
        }
        Task { @MainActor in
            let answer = await self.answer(
                op, body, context: context, in: web
            )
            replyHandler(answer, nil)
        }
    }

    private func sender(of message: WKScriptMessage) -> (WKWebExtensionContext, WKWebView)? {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              let web = message.webView,
              let scheme = web.url?.scheme?.lowercased(),
              Self.isExtensionScheme(scheme),
              urlBelongs(web.url, to: origin),
              web.configuration.websiteDataStore.isPersistent,
              let context = context?(origin.host.lowercased())
        else { return nil }
        return (context, web)
    }

    private func urlBelongs(_ url: URL?, to origin: WKSecurityOrigin) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == origin.`protocol`.lowercased()
            && url.host()?.lowercased() == origin.host.lowercased()
    }

    private static func isExtensionScheme(_ scheme: String) -> Bool {
        scheme == "chrome-extension" || scheme == "webkit-extension"
    }

    private func answer(
        _ op: String, _ body: [String: Any],
        context: WKWebExtensionContext, in web: WKWebView
    ) async -> [String: Any] {
        // A page's own `getDisplayMedia` is allowed without `desktopCapture`
        // (Awesome Screenshot records that way); Chrome's desktop/tab APIs are
        // not.
        if op != "display", !Self.declares(context) {
            return [
                "error": "NotAllowedError",
                "message": "It didn't ask to record your screen",
            ]
        }
        // An offscreen document records only if it was made to.
        if let reasons = ExtensionOffscreen.reasons(of: web),
           reasons.isDisjoint(with: ["USER_MEDIA", "DISPLAY_MEDIA"]) {
            return [
                "error": "NotAllowedError",
                "message": "This offscreen document wasn't made to record",
            ]
        }
        let video = body["video"] ?? true
        // Which picker: a screen, or a window. Chrome's sources in order of
        // preference, or getDisplayMedia's displaySurface.
        let sources = body["sources"] as? [String] ?? []
        let first = sources.first { $0 == "screen" || $0 == "window" || $0 == "tab" }
        let surface = body["surface"] as? String
        let window = first == "window" || first == "tab"
            || surface == "window" || surface == "browser"
        switch op {
        // chooseDesktopMedia, from a page: recorded in that page at once, so
        // a cancelled picker is an empty id, as in Chrome.
        case "choose", "display":
            return await record(
                in: web, token: Self.token(), video: video,
                window: window, context: context
            )
        // An id the worker was given, handed to getUserMedia in a page.
        case "consume":
            guard let token = body["token"] as? String,
                  take(token, for: context.uniqueIdentifier)
            else {
                return ["error": "NotAllowedError", "message": "Invalid state"]
            }
            return await record(
                in: web, token: token, video: video,
                window: window, context: context
            )
        default:
            return ["error": "NotSupportedError", "message": "Unknown request"]
        }
    }

    /// Pages where Chord's own call is under way, and the picker it asks for
    /// (1 a screen, 2 a window). WebKit's question about recording an
    /// extension's page is yes only while one of these is in flight.
    private var inFlight: [ObjectIdentifier: Int] = [:]

    func displayDecision(for web: WKWebView) -> Int {
        inFlight[ObjectIdentifier(web)] ?? 0
    }

    private func record(
        in web: WKWebView, token: String, video: Any,
        window: Bool, context: WKWebExtensionContext
    ) async -> [String: Any] {
        // WebKit won't start a recording in a page that isn't on screen.
        _ = await bringForward?(web)
        inFlight[ObjectIdentifier(web)] = window ? 2 : 1
        let answer = await force(in: web, token: token, video: video)
        inFlight[ObjectIdentifier(web)] = nil
        if answer["ok"] as? Bool == true {
            watch(web, extensionID: context.uniqueIdentifier)
        }
        return answer
    }

    // MARK: - What is recording (1mm.15)

    /// A page that was handed a recording, watched until it stops: WebKit
    /// reports the screen, camera and microphone it is capturing on the view.
    @MainActor
    final class Watched: NSObject {
        struct State: Equatable {
            let extensionID: String
            let screen: Bool
            let camera: Bool
            let microphone: Bool
            var isRecording: Bool { screen || camera || microphone }
        }

        weak var web: WKWebView?
        let extensionID: String
        private let onChange: @MainActor () -> Void
        /// The view's KVO-compliant capture properties: the camera and the
        /// microphone are public; the screen is WebKit's own, when it has it.
        private var keys: [String] = []

        static let displayKey = "_displayCaptureState"

        init(web: WKWebView, extensionID: String, onChange: @escaping @MainActor () -> Void) {
            self.web = web
            self.extensionID = extensionID
            self.onChange = onChange
            super.init()
            keys = ["cameraCaptureState", "microphoneCaptureState"]
            if web.responds(to: NSSelectorFromString(Self.displayKey)) {
                keys.append(Self.displayKey)
            }
            for key in keys { web.addObserver(self, forKeyPath: key, context: nil) }
        }

        var state: State {
            guard let web else {
                return State(extensionID: extensionID, screen: false, camera: false, microphone: false)
            }
            let screen = keys.contains(Self.displayKey)
                && (web.value(forKey: Self.displayKey) as? Int ?? 0) != 0
            return State(
                extensionID: extensionID, screen: screen,
                camera: web.cameraCaptureState != .none,
                microphone: web.microphoneCaptureState != .none
            )
        }

        nonisolated override func observeValue(
            forKeyPath keyPath: String?, of object: Any?,
            change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
        ) {
            Task { @MainActor [weak self] in self?.onChange() }
        }

        func end() {
            if let web {
                for key in keys { web.removeObserver(self, forKeyPath: key) }
            }
            keys = []
        }
    }

    private var watched: [ObjectIdentifier: Watched] = [:]
    private var lastReported: [Watched.State] = []

    func watch(_ web: WKWebView, extensionID: String) {
        let key = ObjectIdentifier(web)
        if watched[key] == nil {
            watched[key] = Watched(web: web, extensionID: extensionID) { [weak self] in
                self?.recordingsChanged()
            }
        }
        recordingsChanged()
    }

    /// Every extension's recording, merged per extension. A page that stopped
    /// or went away is let go.
    var recordings: [Watched.State] {
        var by: [String: Watched.State] = [:]
        for entry in watched.values {
            let now = entry.state
            guard now.isRecording else { continue }
            let before = by[entry.extensionID]
            by[entry.extensionID] = Watched.State(
                extensionID: entry.extensionID,
                screen: now.screen || before?.screen == true,
                camera: now.camera || before?.camera == true,
                microphone: now.microphone || before?.microphone == true
            )
        }
        return by.values.sorted { $0.extensionID < $1.extensionID }
    }

    private func recordingsChanged() {
        // A page asked to record shows nothing for a moment before WebKit
        // reports the capture: only one that has been seen recording and has
        // stopped since (or whose view is gone) is let go.
        for (key, entry) in watched where entry.web == nil {
            entry.end()
            watched[key] = nil
        }
        let now = recordings
        guard now != lastReported else { return }
        let stopped = Set(lastReported.map(\.extensionID)).subtracting(now.map(\.extensionID))
        for (key, entry) in watched where stopped.contains(entry.extensionID) && !entry.state.isRecording {
            entry.end()
            watched[key] = nil
        }
        lastReported = now
        onRecordingsChanged?(now)
    }

    private typealias SetDisplay = @convention(c) (
        AnyObject, Selector, Int, (@convention(block) () -> Void)?
    ) -> Void

    /// Stop: everything the extension is recording ends, and its pages see
    /// their tracks end, as when the Mac's own Stop is used.
    func stop(_ extensionID: String) {
        for entry in watched.values where entry.extensionID == extensionID {
            guard let web = entry.web else { continue }
            let selector = NSSelectorFromString("_setDisplayCaptureState:completionHandler:")
            if web.responds(to: selector),
               let method = class_getMethodImplementation(type(of: web), selector) {
                unsafeBitCast(method, to: SetDisplay.self)(web, selector, 0, nil)
            }
            web.setCameraCaptureState(.none, completionHandler: nil)
            web.setMicrophoneCaptureState(.none, completionHandler: nil)
        }
    }

    private func force(
        in web: WKWebView, token: String, video: Any
    ) async -> [String: Any] {
        do {
            // Called by the app, so WebKit counts it as a click: the page's
            // own getDisplayMedia, kept by the shim before any of the
            // extension's code ran, is called at once, before any await.
            let result = try await web.callAsyncJavaScript(
                "return await globalThis[Symbol.for('chord.capture')](token, video);",
                arguments: ["token": token, "video": video],
                in: nil, contentWorld: .page
            )
            guard let reply = result as? [String: Any] else {
                return ["error": "AbortError", "message": "No answer"]
            }
            if reply["ok"] as? Bool == true {
                return ["ok": true, "token": token]
            }
            return reply
        } catch {
            return ["error": "AbortError", "message": error.localizedDescription]
        }
    }

    // MARK: - Test runs

    /// WebKit's pretend camera, microphone and screen, so a test run records
    /// with no hardware and no macOS question. Never outside a test run.
    static func mockDevices(_ preferences: WKPreferences) {
        set("_setMockCaptureDevicesEnabled:", true, in: preferences)
        set("_setGetUserMediaRequiresFocus:", false, in: preferences)
    }

    /// One of WebKit's preferences it doesn't make public, if it has it.
    static func set(_ name: String, _ on: Bool, in preferences: WKPreferences) {
        let selector = NSSelectorFromString(name)
        guard preferences.responds(to: selector),
              let method = class_getMethodImplementation(type(of: preferences), selector)
        else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method, to: Set.self)(preferences, selector, on)
    }
}
