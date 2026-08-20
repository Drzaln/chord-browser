import Foundation

/// Puts a credential into the fields `PasswordFormMonitor` found (V4 —
/// `docs/design/password-vault.md`).
///
/// The whole difficulty is that setting `input.value` is not how a modern page
/// learns its value changed:
///
/// - **React (and anything with a value tracker) ignores a direct assignment.**
///   It installs an *instance* property override on the input, caches the value
///   it last saw, and treats an `input` event whose value equals the cache as a
///   no-op. Assigning `el.value = x` goes through that override, updates the
///   cache, and the framework concludes nothing happened — the page shows the
///   text and submits an empty string. The fix is to call the **prototype**
///   setter, which bypasses the instance override and leaves the tracker stale,
///   so the framework sees a real change.
/// - Events must then be dispatched by hand, bubbling, because a programmatic
///   value change fires nothing.
///
/// The e2e suite has a page that reproduces the tracker exactly; a unit test
/// cannot see any of this.
enum LoginFormFiller {

    /// JavaScript that fills the given handles and reports what it did.
    ///
    /// Re-checks, in the page, at the moment of filling:
    /// - the element still exists (a SPA may have replaced it since the report),
    /// - it is **still visible** — threat-model rule 5, and the page could have
    ///   hidden it between the offer and the click,
    /// - it is still an `<input>`.
    ///
    /// A refusal here returns `false` rather than throwing: the caller reports
    /// "could not fill", which is the honest outcome, instead of a page that
    /// looks filled but is not.
    static func script(
        usernameFieldID: String?, username: String,
        passwordFieldID: String?, password: String
    ) -> String {
        """
        (function () {
            var wanted = {
                username: \(jsString(usernameFieldID)),
                password: \(jsString(passwordFieldID))
            };
            var values = {
                username: \(jsString(username)),
                password: \(jsString(password))
            };

            // The handles are expandos set by the collector, and the fields may
            // be inside shadow roots (Reddit), so this walks the same way.
            function find(handle, root, found) {
                if (!handle || found.el) { return found; }
                var all = root.querySelectorAll('*');
                for (var i = 0; i < all.length; i++) {
                    var el = all[i];
                    if (el.__chordFieldID === handle) { found.el = el; return found; }
                    if (el.shadowRoot) { find(handle, el.shadowRoot, found); }
                    if (found.el) { return found; }
                }
                return found;
            }

            function isVisible(el) {
                var rect = el.getBoundingClientRect();
                if (rect.width <= 0 || rect.height <= 0) { return false; }
                var style = window.getComputedStyle(el);
                return style.visibility !== 'hidden'
                    && style.display !== 'none'
                    && style.opacity !== '0';
            }

            function fill(el, value) {
                // The prototype setter, NOT el.value = value. See the type doc:
                // going through the instance override updates a framework's value
                // tracker, and the change is then swallowed.
                var proto = el instanceof window.HTMLTextAreaElement
                    ? window.HTMLTextAreaElement.prototype
                    : window.HTMLInputElement.prototype;
                var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
                el.focus();
                setter.call(el, value);
                // Nothing fires on a programmatic change, so both events are
                // dispatched by hand. `input` is what frameworks listen to;
                // `change` is what plain forms and validation listen to.
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
            }

            var filled = { username: false, password: false };
            ['username', 'password'].forEach(function (which) {
                var handle = wanted[which];
                if (!handle) { return; }
                var el = find(handle, document, {}).el;
                if (!el || el.tagName !== 'INPUT') { return; }
                // Rule 5, re-checked at fill time rather than trusted from the
                // earlier report: the page may have hidden it since.
                if (!isVisible(el)) { return; }
                fill(el, values[which]);
                filled[which] = true;
            });
            return JSON.stringify(filled);
        })();
        """
    }

    /// Parses the script's result into which fields actually took a value.
    static func result(from json: String?) -> (username: Bool, password: Bool) {
        guard let json,
            let data = json.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (false, false) }
        return (parsed["username"] as? Bool ?? false, parsed["password"] as? Bool ?? false)
    }

    /// JSON-escapes a value for embedding in the script. A password is arbitrary
    /// text — quotes, backslashes, newlines, `</script>` — and string-concatenating
    /// it into JavaScript would be both a correctness bug and an injection.
    private static func jsString(_ value: String?) -> String {
        guard let value else { return "null" }
        guard let data = try? JSONSerialization.data(
            withJSONObject: [value], options: [.fragmentsAllowed]
        ),
            let array = String(data: data, encoding: .utf8)
        else { return "null" }
        // `["…"]` → `"…"`.
        return String(array.dropFirst().dropLast())
    }
}
