import BrowserCore
import Foundation
import WebKit

/// Bridges the Web Notifications API to macOS Notification Center (non-spec:
/// user-requested).
///
/// Public WKWebView exposes no notification permission or display hook — verified
/// against WKUIDelegate.h — so `window.Notification` is replaced in the page with
/// a shim. The shim reports permission, forwards `new Notification(...)` to the
/// native side over a message handler, and exposes `window.__chordNotifyClick(id)`
/// so a click on the delivered banner can fire that instance's `onclick`.
///
/// This is notifications for a *running* browser whose tab still exists — the tab
/// may be backgrounded or occluded, but the page has to be open. It is not Web
/// Push: background delivery when the site is closed needs APNs / declarative web
/// push, which is Safari-gated and unavailable to a WKWebView app.
enum NotificationBridge {
    /// `new Notification(...)` and `close()` — one-way, no reply needed.
    static let showMessageName = "chordNotifyShow"
    /// `Notification.requestPermission()` — needs the native decision back, so it
    /// is a with-reply handler.
    static let permissionMessageName = "chordNotifyPermission"

    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            // All frames: embedded frames (e.g. chat widgets) post notifications too.
            forMainFrameOnly: false
        )
    }

    /// Parses a `show` message body into a request, or nil if malformed.
    static func request(from body: Any) -> WebNotificationRequest? {
        guard let dict = body as? [String: Any],
              let jsID = dict["id"] as? String,
              let title = dict["title"] as? String
        else { return nil }
        let icon = (dict["icon"] as? String).flatMap(URL.init(string:))
        return WebNotificationRequest(
            jsID: jsID,
            title: title,
            body: dict["body"] as? String ?? "",
            iconURL: icon,
            tag: (dict["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// The JS to run when a delivered notification is clicked, firing the page-side
    /// instance's `onclick` and focusing the window.
    static func clickScript(jsID: String) -> String {
        // The id is our own UUID string, so it needs no escaping, but stay safe.
        let escaped = jsID.replacingOccurrences(of: "'", with: "")
        return "window.__chordNotifyClick && window.__chordNotifyClick('\(escaped)');"
    }

    private static let source = """
    (function () {
        var w = window.webkit && window.webkit.messageHandlers;
        var show = w && w.\(showMessageName);
        var perm = w && w.\(permissionMessageName);
        if (!show || !perm) { return; }

        var permission = 'default';
        var instances = {};
        var counter = 0;

        function uid() {
            counter += 1;
            return 'n' + Date.now() + '_' + counter;
        }

        function ChordNotification(title, options) {
            options = options || {};
            this.title = title;
            this.body = options.body || '';
            this.icon = options.icon || '';
            this.tag = options.tag || '';
            this.onclick = null;
            this.onclose = null;
            this.onshow = null;
            this.onerror = null;
            this._id = uid();
            instances[this._id] = this;

            if (permission === 'granted') {
                show.postMessage({
                    id: this._id, title: String(title),
                    body: String(this.body), icon: String(this.icon),
                    tag: String(this.tag)
                });
                if (typeof this.onshow === 'function') {
                    try { this.onshow(); } catch (e) {}
                }
            }
        }

        ChordNotification.prototype.close = function () {
            delete instances[this._id];
            if (typeof this.onclose === 'function') {
                try { this.onclose(); } catch (e) {}
            }
        };
        // Minimal EventTarget surface some sites probe for.
        ChordNotification.prototype.addEventListener = function (type, cb) {
            if (type === 'click') { this.onclick = cb; }
            else if (type === 'close') { this.onclose = cb; }
            else if (type === 'show') { this.onshow = cb; }
            else if (type === 'error') { this.onerror = cb; }
        };
        ChordNotification.prototype.removeEventListener = function () {};

        Object.defineProperty(ChordNotification, 'permission', {
            get: function () { return permission; }
        });
        ChordNotification.maxActions = 0;

        ChordNotification.requestPermission = function (deprecatedCallback) {
            var p = perm.postMessage({}).then(function (result) {
                permission = (result === 'granted') ? 'granted' : 'denied';
                if (typeof deprecatedCallback === 'function') {
                    try { deprecatedCallback(permission); } catch (e) {}
                }
                return permission;
            });
            return p;
        };

        // Fired natively when a delivered banner is clicked.
        window.__chordNotifyClick = function (id) {
            var n = instances[id];
            if (n && typeof n.onclick === 'function') {
                try { n.onclick(); } catch (e) {}
            }
            try { window.focus(); } catch (e) {}
        };

        window.Notification = ChordNotification;
    })();
    """
}
