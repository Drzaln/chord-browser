import Foundation
import WebKit

/// How an agent's `eval_js` run ended (MCP, 0mu.3).
public enum AgentEvalOutcome: Sendable, Equatable {
    /// The script's return value, as JSON text (or its `String()` when it
    /// isn't JSON-serialisable).
    case value(String)
    /// The script threw; the message.
    case threw(String)
    /// Refused before running: a password is filled in on the page.
    case passwordFilled
    case timedOut
    /// The pane has no live view.
    case noView
}

/// Runs an agent's JavaScript in a content world of its own (0mu.3).
///
/// Its own world, not the page's (the site cannot see or tamper with the
/// run), not the password monitor's, and not the one holding the action
/// tools' element refs. Before the agent's code runs, the world is hardened
/// once per document:
///
/// - `document.cookie` reads empty and ignores writes;
/// - `localStorage`, `sessionStorage` and `indexedDB` throw;
/// - a password input's `value` reads empty and refuses writes;
/// - and the run is refused outright if any password field has a value,
///   checked with the native getter before the override goes in.
///
/// Each override is non-configurable, so the agent's code cannot put the
/// original back in this world. This is defence in depth, not a sandbox:
/// a same-origin iframe's fresh prototypes, `FormData` and other routes can
/// still reach the DOM. The real controls are the switch being off by
/// default, the per-run confirmation, and Read & Act Spaces only.
enum AgentEvalScript {
    static let passwordMarker = "CHORD_PASSWORD_FILLED"

    static let prelude = #"""
    if (!window.__chordPasswordFilled) {
        // Everything that can read a real password value lives in this
        // closure. What escapes it is one yes/no function, so the agent's
        // code never gets hold of the native getter.
        const nativeValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value");
        const isPassword = (el) => (el.type || "").toLowerCase() === "password";
        const passwords = (root, out) => {
            for (const el of root.querySelectorAll("input")) if (isPassword(el)) out.push(el);
            for (const host of root.querySelectorAll("*")) if (host.shadowRoot) passwords(host.shadowRoot, out);
            return out;
        };
        const lock = (target, name, descriptor) => {
            try { Object.defineProperty(target, name, { configurable: false, ...descriptor }); } catch (e) {}
        };
        lock(Document.prototype, "cookie", { get() { return ""; }, set(v) {} });
        for (const name of ["localStorage", "sessionStorage", "indexedDB"]) {
            const get = () => { throw new Error("Chord does not give agent scripts " + name); };
            lock(window, name, { get });
            lock(Window.prototype, name, { get });
        }
        lock(HTMLInputElement.prototype, "value", {
            get() { return isPassword(this) ? "" : nativeValue.get.call(this); },
            set(v) {
                if (isPassword(this)) throw new Error("Chord does not let agent scripts touch password fields");
                nativeValue.set.call(this, v);
            }
        });
        lock(window, "__chordPasswordFilled", {
            value: () => passwords(document, []).some(el => nativeValue.get.call(el).length > 0),
            writable: false
        });
    }
    if (window.__chordPasswordFilled()) throw new Error("CHORD_PASSWORD_FILLED");
    """#

    /// The full body handed to `callAsyncJavaScript`: the prelude, then the
    /// agent's code as an async function body, then its result as JSON.
    static func body(for script: String) -> String {
        prelude + """

            const __chordResult = await (async () => {
            \(script)
            })();
            if (__chordResult === undefined) return "null";
            try { return JSON.stringify(__chordResult); } catch (e) { return JSON.stringify(String(__chordResult)); }
            """
    }

    @MainActor
    static func run(
        _ script: String, in webView: WKWebView, world: WKContentWorld, timeout: Duration
    ) async -> AgentEvalOutcome {
        // `callAsyncJavaScript` cannot be cancelled, and a task group would
        // wait for it, so a script that never settles would hang the tool.
        // Whichever finishes first resumes; the other is ignored.
        await withCheckedContinuation { continuation in
            var resumed = false
            let finish: @MainActor (AgentEvalOutcome) -> Void = { outcome in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: outcome)
            }
            Task { @MainActor in
                do {
                    let value = try await webView.callAsyncJavaScript(
                        body(for: script), arguments: [:], contentWorld: world
                    )
                    finish(.value(value as? String ?? "null"))
                } catch {
                    let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                        ?? error.localizedDescription
                    finish(message.contains(passwordMarker) ? .passwordFilled : .threw(message))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                finish(.timedOut)
            }
        }
    }
}
