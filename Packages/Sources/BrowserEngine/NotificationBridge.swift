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
    static func makeUserScript(
        notificationPermission: WebNotificationPermission = .notDetermined
    ) -> WKUserScript {
        WKUserScript(
            source: source(notificationPermission: notificationPermission),
            injectionTime: .atDocumentStart,
            // All frames: embedded frames (e.g. chat widgets) post notifications too.
            forMainFrameOnly: false
        )
    }

    /// JS to push a fresh notification-permission decision into a *live* page,
    /// so a grant made mid-session (or read from the OS after launch) reaches
    /// pages that were already open — not just ones loaded afterwards.
    static func updatePermissionScript(_ permission: WebNotificationPermission) -> String {
        "window.__chordSetNotificationPermission && "
            + "window.__chordSetNotificationPermission('\(permission.jsValue)');"
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

    private static func source(notificationPermission: WebNotificationPermission) -> String {
    """
    (function () {
        var w = window.webkit && window.webkit.messageHandlers;
        var show = w && w.\(showMessageName);
        var perm = w && w.\(permissionMessageName);
        if (!show || !perm) { return; }

        // Seeded from the OS authorization the user already granted (or denied),
        // so a returning page reads its real permission instead of 'default' and
        // does not re-prompt. Native pushes updates via __chordSetNotificationPermission.
        var permission = '\(notificationPermission.jsValue)';
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
            // Already decided: resolve from the seeded state without prompting
            // again — the OS remembers the grant across launches.
            if (permission === 'granted' || permission === 'denied') {
                if (typeof deprecatedCallback === 'function') {
                    try { deprecatedCallback(permission); } catch (e) {}
                }
                return Promise.resolve(permission);
            }
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

        // Native pushes the current OS notification decision here (at launch, or
        // right after the user answers the prompt) so already-open pages update.
        window.__chordSetNotificationPermission = function (value) {
            permission = value;
        };

        window.Notification = ChordNotification;

        // --- Permissions API (notifications only) ------------------------------
        // Mirror the notification decision from `permission` above into
        // navigator.permissions.query({name:'notifications'}), which WKWebView
        // otherwise reports as 'prompt' on every launch.
        //
        // We deliberately do NOT touch camera/microphone here. WKWebView does not
        // support querying those names (the native call rejects), and reporting a
        // synthetic 'granted' makes Google Meet take a path that fails outright
        // ("Couldn't start the video call"). getUserMedia is still auto-granted at
        // the WKUIDelegate layer, so camera/mic work; Meet just shows its own
        // pre-join access prompt, which is correct for a browser that does not
        // persist media grants.
        //
        // We never hand back a fake object when the native query works: we wrap
        // the real PermissionStatus in a Proxy overriding only `state`, so
        // instanceof, `change` events, and identity stay intact.
        function chordOverrideState(name) {
            if (name === 'notifications') {
                return (permission === 'default') ? 'prompt' : permission;
            }
            return null;
        }
        try {
            var nav = window.navigator;
            if (nav && nav.permissions && typeof nav.permissions.query === 'function') {
                var nativeQuery = nav.permissions.query.bind(nav.permissions);
                nav.permissions.query = function (desc) {
                    var name = desc && desc.name;
                    var override = chordOverrideState(name);
                    return nativeQuery(desc).then(function (status) {
                        if (!override || !status) { return status; }
                        return new Proxy(status, {
                            get: function (target, prop) {
                                if (prop === 'state') { return override; }
                                var value = target[prop];
                                return (typeof value === 'function')
                                    ? value.bind(target) : value;
                            }
                        });
                    }, function (err) {
                        if (!override) { throw err; }
                        return {
                            name: name, state: override, onchange: null,
                            addEventListener: function () {},
                            removeEventListener: function () {},
                            dispatchEvent: function () { return false; }
                        };
                    });
                };
            }
        } catch (e) {}
    })();
    """
    }
}
