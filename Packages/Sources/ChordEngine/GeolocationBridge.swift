import ChordCore
import Foundation
import WebKit

/// Bridges `navigator.geolocation` to the host's `CLLocationManager`
/// (non-spec: user-requested).
///
/// macOS WKWebView ships no geolocation provider — WebKit's CoreLocation
/// provider is iOS-only (`WKGeolocationProviderIOS`) — so the native permission
/// delegate never fires and a page's geolocation is silently denied (verified
/// in the field: "Google Maps does not have permission to use your location",
/// with no TCC prompt). So `navigator.geolocation` is replaced in the page with
/// a shim that asks the native side three questions over a with-reply message
/// handler:
/// - `query` — the remembered per-origin decision, no prompt. Seeds the page at
///   load and mirrors into `navigator.permissions.query({name:'geolocation'})`.
/// - `request` — a real per-origin prompt the first time (ask-once, same path
///   as camera/mic), then the remembered answer.
/// - `position` — one fix from the host's `CLLocationManager`, which is also
///   what surfaces the OS TCC prompt on first use.
///
/// `watchPosition` polls `position` in-page, so leaving the page stops it for
/// free. This is the Electron-on-macOS approach, applied to WKWebView.
enum GeolocationBridge {
    /// The with-reply handler name, registered in the page world.
    static let messageName = "chordGeolocation"

    /// Injected at document start into every frame, so a `watchPosition` begun
    /// before the page finishes loading is still shimmed.
    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// The `op` a message carries: `query`, `request`, or `position`.
    static func op(from body: Any) -> String? {
        (body as? [String: Any])?["op"] as? String
    }

    /// Serializes a fix into the JS shape the shim turns into a
    /// `GeolocationPosition`. Absent optional fields are omitted so the page
    /// sees null rather than a bridged empty value.
    static func positionPayload(_ coordinate: WebGeolocationCoordinate) -> [String: Any] {
        var payload: [String: Any] = [
            "latitude": coordinate.latitude,
            "longitude": coordinate.longitude,
            "accuracy": coordinate.accuracy,
            "timestamp": coordinate.timestamp.timeIntervalSince1970 * 1000,
        ]
        if let altitude = coordinate.altitude { payload["altitude"] = altitude }
        if let altitudeAccuracy = coordinate.altitudeAccuracy {
            payload["altitudeAccuracy"] = altitudeAccuracy
        }
        if let heading = coordinate.heading { payload["heading"] = heading }
        if let speed = coordinate.speed { payload["speed"] = speed }
        return payload
    }

    private static let source = """
    (function () {
        var handler = window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.\(messageName);
        if (!handler) { return; }

        // Install exactly once per window. `atDocumentStart` can run more than
        // once against the same page (re-injection, about:blank handovers); a
        // second run must only refresh the handler, never rebuild `state`.
        if (window.__chordGeo) {
            window.__chordGeo.handler = handler;
            return;
        }
        var state = { permission: null, watchers: {}, counter: 0, handler: handler };
        window.__chordGeo = state;

        function ask(op) { return state.handler.postMessage({ op: op }); }

        function permission() {
            if (state.permission) { return Promise.resolve(state.permission); }
            return ask('query').then(function (p) {
                state.permission = p;
                return p;
            });
        }

        // Granted → proceed; denied → error; prompt → ask once (may prompt).
        function ensure() {
            return permission().then(function (p) {
                if (p !== 'prompt') { return p === 'granted'; }
                return ask('request').then(function (r) {
                    state.permission = r;
                    return r === 'granted';
                });
            });
        }

        function toPosition(payload) {
            return {
                coords: {
                    latitude: payload.latitude,
                    longitude: payload.longitude,
                    accuracy: payload.accuracy,
                    altitude: payload.altitude != null ? payload.altitude : null,
                    altitudeAccuracy: payload.altitudeAccuracy != null
                        ? payload.altitudeAccuracy : null,
                    heading: payload.heading != null ? payload.heading : null,
                    speed: payload.speed != null ? payload.speed : null
                },
                timestamp: payload.timestamp || Date.now()
            };
        }

        function fail(cb, code, message) {
            var err = { code: code, message: message };
            err.PERMISSION_DENIED = 1;
            err.POSITION_UNAVAILABLE = 2;
            err.TIMEOUT = 3;
            if (typeof cb === 'function') {
                try { cb(err); } catch (e) {}
            }
        }

        function locate(success, error, options) {
            ensure().then(function (granted) {
                if (!granted) {
                    fail(error, 1, 'User denied geolocation');
                    return;
                }
                return ask('position').then(function (payload) {
                    if (!payload || payload.error) {
                        fail(error, 2, payload && payload.error || 'Position unavailable');
                        return;
                    }
                    if (typeof success === 'function') {
                        try { success(toPosition(payload)); } catch (e) {}
                    }
                });
            }).catch(function (e) {
                fail(error, 2, 'Position unavailable');
            });
        }

        var geo = {
            getCurrentPosition: function (success, error, options) {
                locate(success, error, options);
            },
            watchPosition: function (success, error, options) {
                state.counter += 1;
                var id = 'g' + state.counter;
                // Poll. `maximumAge` below 60s asks for fresher data, so poll
                // faster; otherwise a coarser 3s cadence is plenty for maps.
                var maxAge = options && typeof options.maximumAge === 'number'
                    ? options.maximumAge : 0;
                var interval = (maxAge > 0 && maxAge < 60000)
                    ? Math.max(1000, maxAge) : 3000;
                locate(success, error, options);
                state.watchers[id] = setInterval(function () {
                    locate(success, error, options);
                }, interval);
                return id;
            },
            clearWatch: function (id) {
                var timer = state.watchers[id];
                if (timer) { clearInterval(timer); delete state.watchers[id]; }
            }
        };

        try {
            Object.defineProperty(navigator, 'geolocation', {
                value: geo, configurable: true, writable: true
            });
        } catch (e) {}

        // --- Permissions API (geolocation only) -------------------------------
        // Mirror the remembered per-origin decision into
        // navigator.permissions.query({name:'geolocation'}), which WKWebView
        // otherwise cannot answer. Only geolocation is overridden — everything
        // else passes through to the native query untouched.
        try {
            var nav = window.navigator;
            if (nav.permissions && typeof nav.permissions.query === 'function') {
                var nativeQuery = nav.permissions.query.bind(nav.permissions);
                nav.permissions.query = function (desc) {
                    var name = desc && desc.name;
                    if (name === 'geolocation') {
                        return permission().then(function (p) {
                            return {
                                name: 'geolocation', state: p, onchange: null,
                                addEventListener: function () {},
                                removeEventListener: function () {},
                                dispatchEvent: function () { return false; }
                            };
                        });
                    }
                    return nativeQuery(desc);
                };
            }
        } catch (e) {}
    })();
    """
}