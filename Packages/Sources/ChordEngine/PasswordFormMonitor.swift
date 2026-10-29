import ChordCore
import Foundation
import WebKit

/// Reports the login fields a page is showing, so the vault can offer to fill
/// them (V3 — `docs/design/password-vault.md`).
///
/// **The script decides nothing.** It collects a descriptor per input and posts
/// it; `LoginFormClassifier` in `ChordCore` judges. That split is what lets the
/// hard part — which field is the username, is this a signup, is that a honeypot —
/// be tested against captured markup from real sites with no browser involved.
///
/// Three things it must get right, each learned from a live page (V3 spike, and
/// the corpus in `LoginFormClassifierTests`):
///
/// - **Pierce open shadow roots.** Reddit's login has *zero* inputs in the light
///   DOM; the fields live inside 46 shadow hosts. `querySelectorAll('input')`
///   finds nothing there, and the page would simply not exist to the vault.
/// - **Report live visibility**, from rects and computed style rather than
///   attributes. Google renders a hidden decoy password field, GitHub ships three
///   invisible honeypots, and Mixpanel keeps its password field hidden until the
///   email step passes — ignoring invisible fields defeats all three at once, and
///   is threat-model rule 5.
/// - **Re-run on mutation.** Every site in the corpus is a single-page app; the
///   login form usually does not exist at `DOMContentLoaded`.
///
/// **Main frame only** (rule 3): a credential is never filled inside an iframe,
/// so there is no reason to look in one.
enum PasswordFormMonitor {
    static let messageName = "chordLoginForm"

    /// What a submitted login carried (V5). The password crosses the bridge here
    /// — that is unavoidable for capture, and it is the one message in the app
    /// that must never be logged.
    struct SubmittedLogin: Equatable, Sendable {
        let username: String
        let password: String
    }

    /// The world the monitor and `LoginFormFiller` share: the fields are
    /// tagged with an expando, and expandos are per world.
    ///
    /// From macOS 27 it is a world of Chord's own that sees closed shadow
    /// roots as open ones, so a login a site keeps behind one is still found,
    /// and that the page cannot reach: a page could otherwise read the
    /// password as it is filled, by replacing the value setter the filler
    /// calls, or post a login report or submission of its own invention.
    /// Before 27 there is no such world, and the page's is kept.
    @MainActor
    static let world: WKContentWorld = {
        if #available(macOS 27.0, *), let world = closedRootsWorld() { return world }
        return .page
    }()

    /// `WKContentWorld.Configuration` is macOS 27 and absent from the macOS 26
    /// SDK the release CI builds against, so it is built by name, as
    /// `applyReferrer` sets `overrideReferrer`. Nil where the runtime has no
    /// such world.
    @MainActor
    private static func closedRootsWorld() -> WKContentWorld? {
        guard let type = NSClassFromString("WKContentWorldConfiguration") as? NSObject.Type
        else { return nil }
        let configuration = type.init()
        configuration.setValue(true, forKey: "allowAccessingClosedShadowRoots")
        let make = NSSelectorFromString("worldWithConfiguration:")
        guard WKContentWorld.responds(to: make) else { return nil }
        return WKContentWorld.perform(make, with: configuration)?
            .takeUnretainedValue() as? WKContentWorld
    }

    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            // Rule 3: main frame only. Never fill inside an iframe.
            forMainFrameOnly: true,
            in: world
        )
    }

    /// Parses a reported payload into descriptors for the classifier. Returns nil
    /// for a malformed message rather than guessing — a garbled descriptor is a
    /// wrong fill target.
    /// A submitted login, if that is what this message is (V5).
    ///
    /// **A username with no password is still reported** (V6). Multi-step logins
    /// — Google's, most notably — put the username on one page and the password
    /// on the next, so the password-step submission carries no username at all.
    /// The store remembers the username from the earlier step and pairs them;
    /// without this, Google would save a credential with a blank username.
    static func submission(from body: Any) -> SubmittedLogin? {
        guard let payload = body as? [String: Any],
            payload["op"] as? String == "submit"
        else { return nil }
        let username = payload["username"] as? String ?? ""
        let password = payload["password"] as? String ?? ""
        // Nothing at all is not a submission worth reporting.
        guard !username.isEmpty || !password.isEmpty else { return nil }
        return SubmittedLogin(username: username, password: password)
    }

    static func fields(from body: Any) -> [LoginFieldDescriptor]? {
        guard let payload = body as? [String: Any],
            let rawFields = payload["fields"] as? [[String: Any]]
        else { return nil }

        return rawFields.enumerated().compactMap { index, raw in
            guard let elementID = raw["elementID"] as? String, !elementID.isEmpty,
                let type = raw["type"] as? String
            else { return nil }
            return LoginFieldDescriptor(
                elementID: elementID,
                type: type,
                autocomplete: raw["autocomplete"] as? String ?? "",
                name: raw["name"] as? String ?? "",
                id: raw["id"] as? String ?? "",
                placeholder: raw["placeholder"] as? String ?? "",
                label: raw["label"] as? String ?? "",
                ariaLabel: raw["ariaLabel"] as? String ?? "",
                isVisible: raw["visible"] as? Bool ?? false,
                index: raw["index"] as? Int ?? index
            )
        }
    }

    private static let source = """
    (function () {
        var handler = window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.\(messageName);
        if (!handler) { return; }
        // atDocumentStart can run more than once against one document
        // (re-injection, about:blank handovers). One observer, one state.
        if (window.__chordLoginForms) { return; }
        window.__chordLoginForms = { seq: 0, last: null };
        var state = window.__chordLoginForms;

        // A handle the fill step can turn back into this element. An expando on
        // the node, not an id attribute: writing to the page's id would be a
        // visible side effect and could collide with the site's own CSS or JS.
        function handleFor(el) {
            if (!el.__chordFieldID) {
                state.seq += 1;
                el.__chordFieldID = 'chord-field-' + state.seq;
            }
            return el.__chordFieldID;
        }

        function isVisible(el) {
            var rect = el.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0) { return false; }
            var style = window.getComputedStyle(el);
            return style.visibility !== 'hidden'
                && style.display !== 'none'
                && style.opacity !== '0';
        }

        function labelFor(el) {
            if (el.labels && el.labels.length) {
                return (el.labels[0].innerText || '').trim().slice(0, 80);
            }
            var wrapping = el.closest && el.closest('label');
            if (wrapping) { return (wrapping.innerText || '').trim().slice(0, 80); }
            var labelledBy = el.getAttribute('aria-labelledby');
            if (labelledBy) {
                var node = document.getElementById(labelledBy);
                if (node) { return (node.innerText || '').trim().slice(0, 80); }
            }
            return '';
        }

        // Reddit's login is entirely inside shadow roots — a plain
        // querySelectorAll finds nothing at all there.
        function collectInputs(root, found) {
            var all = root.querySelectorAll('*');
            for (var i = 0; i < all.length; i++) {
                var el = all[i];
                if (el.tagName === 'INPUT') { found.push(el); }
                if (el.shadowRoot) { collectInputs(el.shadowRoot, found); }
            }
            return found;
        }

        var ignoredTypes = ['hidden', 'submit', 'button', 'checkbox', 'radio', 'image', 'file'];

        // The inputs the last report saw, so a change around them is noticed
        // without rescanning the page for every unrelated mutation.
        var tracked = [];

        function describe() {
            var elements = collectInputs(document, []);
            tracked = elements;
            var fields = [];
            for (var i = 0; i < elements.length; i++) {
                var el = elements[i];
                var type = (el.type || '').toLowerCase();
                if (ignoredTypes.indexOf(type) !== -1) { continue; }
                fields.push({
                    elementID: handleFor(el),
                    type: type,
                    autocomplete: el.getAttribute('autocomplete') || '',
                    name: el.name || '',
                    id: el.id || '',
                    placeholder: el.placeholder || '',
                    label: labelFor(el),
                    ariaLabel: el.getAttribute('aria-label') || '',
                    visible: isVisible(el),
                    index: fields.length
                });
            }
            return fields;
        }

        function report() {
            var fields = describe();
            // Only speak when something changed: these pages mutate constantly,
            // and a message per mutation would be a message per animation frame.
            var signature = JSON.stringify(fields);
            if (signature === state.last) { return; }
            state.last = signature;
            handler.postMessage({ fields: fields });
        }

        // --- Capture (V5) -------------------------------------------------
        // What the user typed, read at the moment of submission. Kept out of the
        // field reports above: those go out on every mutation, and a password
        // has no business being in them.
        function currentLogin() {
            var fields = describe();
            var username = null;
            var password = null;
            var elements = collectInputs(document, []);
            var byHandle = {};
            for (var i = 0; i < elements.length; i++) {
                byHandle[elements[i].__chordFieldID] = elements[i];
            }
            for (var j = 0; j < fields.length; j++) {
                var field = fields[j];
                if (!field.visible) { continue; }
                var el = byHandle[field.elementID];
                if (!el) { continue; }
                if (field.type === 'password' && password === null && el.value) {
                    password = el.value;
                } else if (field.type !== 'password' && username === null && el.value) {
                    username = el.value;
                }
            }
            // A username-only step counts: see `submission(from:)`.
            if (!password && !username) { return null; }
            return { username: username || '', password: password || '' };
        }

        function reportSubmission() {
            var login = currentLogin();
            if (!login) { return; }
            handler.postMessage({
                op: 'submit', username: login.username, password: login.password
            });
        }

        // A real form submit.
        document.addEventListener('submit', reportSubmission, true);
        // Single-page apps often never submit a form: the button posts with
        // fetch() and the fields disappear. Losing the credential on exactly the
        // sites most likely to have one is not acceptable, so a click on a
        // plausible submit control reports too. Duplicates are harmless — the
        // store collapses a repeat of the same (origin, username, password).
        document.addEventListener('click', function (event) {
            var target = event.target;
            if (!target || !target.closest) { return; }
            var button = target.closest('button, input[type=submit], [role=button]');
            if (!button) { return; }
            setTimeout(reportSubmission, 0);
        }, true);
        // Enter in a password field, for forms with no button at all.
        document.addEventListener('keydown', function (event) {
            if (event.key !== 'Enter') { return; }
            var el = event.target;
            if (el && el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'password') {
                setTimeout(reportSubmission, 0);
            }
        }, true);

        var pending = null;
        var lastScan = 0;
        function scheduleReport() {
            if (pending) { return; }
            pending = setTimeout(function () {
                pending = null;
                lastScan = Date.now();
                report();
            }, 150);
        }

        // Whether `node` is `ancestor` or inside it, across shadow roots.
        function within(ancestor, node) {
            for (var n = node; n; n = n.parentNode || n.host) {
                if (n === ancestor) { return true; }
            }
            return false;
        }

        function bringsInputs(node) {
            return node.nodeType === 1 && (node.tagName === 'INPUT'
                || (node.querySelector && node.querySelector('input') !== null));
        }

        // Whether a batch of mutations could change what the page reports:
        // an input added or removed, an input's own attributes, or a change
        // on something holding a field already seen (a parent unhiding it).
        // Everything else — progress bars, animations, feeds — cannot, and a
        // full scan of every element and shadow root for each of those cost
        // busy pages several scans a second, for good.
        function relevant(records) {
            for (var i = 0; i < records.length; i++) {
                var record = records[i];
                if (record.type === 'childList') {
                    var lists = [record.addedNodes, record.removedNodes];
                    for (var l = 0; l < 2; l++) {
                        for (var j = 0; j < lists[l].length; j++) {
                            if (bringsInputs(lists[l][j])) { return true; }
                        }
                    }
                } else {
                    var target = record.target;
                    if (target.tagName === 'INPUT') { return true; }
                    for (var k = 0; k < tracked.length; k++) {
                        if (within(target, tracked[k])) { return true; }
                    }
                }
            }
            return false;
        }

        // The login form usually does not exist yet at document start — every
        // site in the corpus renders it client-side. A relevant change is
        // looked at within 150 ms. Any other change still earns a look within
        // a couple of seconds, never sooner: the observer cannot see inside
        // shadow roots, where some logins (Reddit's) render after load.
        var later = null;
        var observer = new MutationObserver(function (records) {
            if (relevant(records)) { scheduleReport(); return; }
            if (later || pending) { return; }
            later = setTimeout(function () {
                later = null;
                scheduleReport();
            }, Math.max(150, 2000 - (Date.now() - lastScan)));
        });
        function observe() {
            observer.observe(document.documentElement || document, {
                childList: true, subtree: true, attributes: true,
                attributeFilter: ['type', 'autocomplete', 'style', 'class', 'hidden']
            });
        }

        if (document.documentElement) { observe(); }
        document.addEventListener('DOMContentLoaded', function () {
            observe();
            report();
        });
        // A field can become visible without any mutation we observe (a parent
        // unhiding via a stylesheet, for instance), so a focus is also a cue.
        document.addEventListener('focusin', scheduleReport, true);
        scheduleReport();
    })();
    """
}
