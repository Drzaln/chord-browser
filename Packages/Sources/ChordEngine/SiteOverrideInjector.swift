import ChordCore
import Foundation
import WebKit

/// Injects a site's override CSS (and, if any, its user JS) at document start
/// (non-spec: user-requested, ADR 024).
///
/// Host-guarded in the page rather than resolved natively: a web view navigates,
/// and the ruleset has to follow it without a round trip to native on every
/// document. That is also why the rules travel serialized inside the script —
/// asking the app on each document start would cost a synchronous message before
/// first paint.
///
/// **One script for CSS, one per override for JS.** Inlining every override's JS
/// into the CSS script would mean a single syntax error in any user script stops
/// the whole script from parsing, taking every site's CSS down with it. Separate
/// scripts contain that: a broken override breaks only itself.
///
/// Empty when nothing is enabled, so an install with no overrides installs no
/// scripts and registers no handler (the same frugality as the developer-only DRM
/// monitor).
enum SiteOverrideInjector {
    /// The `<style>` element the injected CSS lives in. Named so the page (and a
    /// curious user) can see where the rules came from.
    static let styleElementID = "chord-site-override"

    @MainActor
    static func makeUserScripts(overrides: [SiteOverride]) -> [WKUserScript] {
        let active = overrides.filter { $0.isEnabled && $0.hasContent }
        guard !active.isEmpty else { return [] }
        var scripts: [WKUserScript] = []
        if active.contains(where: { !SiteOverrides.stylesheet(for: $0).isEmpty }) {
            scripts.append(
                WKUserScript(
                    source: cssSource(overrides: active),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        }
        for override in active
        where !override.js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scripts.append(
                WKUserScript(
                    source: jsSource(for: override),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        }
        return scripts
    }

    /// The stylesheet script: every enabled override's CSS, chosen by host.
    /// Split out so the text can be checked in a test without building a web
    /// view.
    static func cssSource(overrides: [SiteOverride]) -> String {
        let rules = overrides.map { override in
            ["pattern": override.pattern, "css": SiteOverrides.stylesheet(for: override)]
        }
        let rulesJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: rules, options: []),
            let string = String(data: data, encoding: .utf8)
        {
            rulesJSON = string
        } else {
            rulesJSON = "[]"
        }

        return """
            (function () {
                var RULES = \(rulesJSON);
                var host = (location.hostname || '').toLowerCase();

                // Subdomain match, most specific wins — the same rule as
                // RouteRules/SiteOverrides in Swift. The suffix must follow a dot,
                // so `example.com` never matches `notexample.com`.
                function matches(pattern) {
                    return host === pattern
                        || (host.length > pattern.length + 1
                            && host.slice(-(pattern.length + 1)) === '.' + pattern);
                }

                var chosen = null;
                for (var i = 0; i < RULES.length; i++) {
                    if (!matches(RULES[i].pattern)) { continue; }
                    if (!chosen || RULES[i].pattern.length > chosen.pattern.length) {
                        chosen = RULES[i];
                    }
                }
                if (!chosen || !chosen.css) { return; }

                function install(css) {
                    var apply = function () {
                        var style = document.getElementById('\(styleElementID)');
                        if (!style) {
                            style = document.createElement('style');
                            style.id = '\(styleElementID)';
                            var parent = document.head || document.documentElement;
                            if (!parent) { return false; }
                            parent.appendChild(style);
                        }
                        style.textContent = css;
                        return true;
                    };
                    if (!apply()) {
                        document.addEventListener('DOMContentLoaded', apply, { once: true });
                    }
                }

                install(chosen.css);
            })();
            """
    }

    /// One override's user JS, inline and host-guarded.
    ///
    /// Inline rather than `eval`'d: an injected `eval` is subject to the page's
    /// CSP, and a site that forbids it would silently swallow the override. The
    /// try/catch catches a runtime throw; a syntax error still breaks this script
    /// — and only this script, which is why it is not merged with the CSS one.
    static func jsSource(for override: SiteOverride) -> String {
        """
        (function () {
            var host = (location.hostname || '').toLowerCase();
            var pattern = \(quoted(override.pattern));
            var matches = host === pattern
                || (host.length > pattern.length + 1
                    && host.slice(-(pattern.length + 1)) === '.' + pattern);
            if (!matches) { return; }
            try {
                (function () {
        \(override.js)
                })();
            } catch (error) {
                console.error('Chord site override:', error);
            }
        })();
        """
    }

    /// A JS/JSON string literal for a Swift string, escaped by Foundation rather
    /// than by hand — a host is user input and could contain a quote.
    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
            let string = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return string
    }
}
