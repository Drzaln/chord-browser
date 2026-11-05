import Foundation
import WebKit

/// One thing a local agent asks of a page (MCP, 0mu.2). Each case runs a fixed
/// script, so the store can act on a page without ever sending it code — an
/// arbitrary-JavaScript tool is 0mu.3's, behind its own switch.
public enum AgentPageRequest: Sendable, Equatable {
    /// Interactive elements, each with a ref the other requests take.
    case listElements(limit: Int)
    /// What an element is, before acting on it: role, label, and its form.
    case describe(ref: String)
    case click(ref: String)
    /// Types into a field (or picks a `<select>` option by text or value).
    /// Refuses password fields. `submit` submits the field's form, or presses
    /// Enter when there is none.
    case type(ref: String, text: String, clear: Bool, submit: Bool)
    /// Scrolls an element into view, or the page by `pages` viewport heights.
    case scroll(ref: String?, pages: Double)
    /// Whether the page's visible text contains this.
    case findText(String)

    var operation: String {
        switch self {
        case .listElements: "list"
        case .describe: "describe"
        case .click: "click"
        case .type: "type"
        case .scroll: "scroll"
        case .findText: "find"
        }
    }

    /// The request's arguments as a JSON object string, parsed by the script.
    var argumentJSON: String {
        var object: [String: Any] = ["op": operation]
        switch self {
        case .listElements(let limit): object["limit"] = limit
        case .describe(let ref), .click(let ref): object["ref"] = ref
        case .type(let ref, let text, let clear, let submit):
            object["ref"] = ref
            object["text"] = text
            object["clear"] = clear
            object["submit"] = submit
        case .scroll(let ref, let pages):
            if let ref { object["ref"] = ref }
            object["pages"] = pages
        case .findText(let text): object["text"] = text
        }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// The script behind `AgentPageRequest`, run in the agent's own content world.
///
/// Refs are kept in that world (a `Map` of `WeakRef`s), not written onto the
/// DOM: the page cannot read them, forge them or move them to another element.
/// Events dispatched here reach the page's listeners as usual, since the DOM
/// is shared between worlds; only the JavaScript globals are not.
enum AgentPageScript {
    /// Runs one request and returns its result as JSON text, nil if it threw.
    @MainActor
    static func run(_ request: AgentPageRequest, in webView: WKWebView, world: WKContentWorld) async -> String? {
        do {
            // The script's top-level `return`s sit inside an async arrow; the
            // result is stringified out here, so a plain string crosses back
            // instead of WebKit's dictionary bridging.
            let value = try await webView.callAsyncJavaScript(
                "const result = await (async () => {\n" + source
                    + "\n})();\nreturn JSON.stringify(result ?? null);",
                arguments: ["argJSON": request.argumentJSON],
                contentWorld: world
            )
            return value as? String
        } catch {
            Log.engine.debug("agent \(request.operation) failed: \(error.localizedDescription)")
            return nil
        }
    }

    static let source = #"""
    const arg = JSON.parse(argJSON);
    const S = window.__chordAgent || (window.__chordAgent = { next: 1, refs: new Map(), ids: new WeakMap() });

    const clean = (s, n = 120) => (s || "").replace(/\s+/g, " ").trim().slice(0, n);
    const refFor = (el) => {
        let ref = S.ids.get(el);
        if (!ref) { ref = "e" + (S.next++); S.ids.set(el, ref); }
        S.refs.set(ref, new WeakRef(el));
        return ref;
    };
    const lookup = (ref) => {
        const el = S.refs.get(ref)?.deref();
        return el && el.isConnected ? el : null;
    };
    const visible = (el) => {
        const r = el.getBoundingClientRect();
        if (r.width < 1 || r.height < 1) return false;
        const s = getComputedStyle(el);
        return s.visibility !== "hidden" && s.display !== "none" && parseFloat(s.opacity || "1") > 0;
    };
    const inViewport = (el) => {
        const r = el.getBoundingClientRect();
        return r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
    };
    const roleOf = (el) => {
        const explicit = el.getAttribute("role");
        if (explicit) return explicit;
        const tag = el.tagName.toLowerCase();
        if (tag === "a") return "link";
        if (tag === "button" || tag === "summary") return "button";
        if (tag === "select") return "combobox";
        if (tag === "textarea" || el.isContentEditable) return "textbox";
        if (tag === "input") {
            const t = (el.type || "text").toLowerCase();
            if (["button", "submit", "reset", "image"].includes(t)) return "button";
            if (t === "checkbox" || t === "radio") return t;
            if (t === "search") return "searchbox";
            return "textbox";
        }
        return tag;
    };
    const labelOf = (el) => {
        if (!el) return "";
        const aria = el.getAttribute("aria-label");
        if (aria) return clean(aria);
        const by = el.getAttribute("aria-labelledby");
        if (by) {
            const text = by.split(/\s+/).map(id => document.getElementById(id)?.innerText || "").join(" ");
            if (clean(text)) return clean(text);
        }
        if (el.labels && el.labels.length) return clean(el.labels[0].innerText);
        const tag = el.tagName.toLowerCase();
        if (tag === "input" && ["button", "submit", "reset"].includes((el.type || "").toLowerCase())) {
            return clean(el.value);
        }
        return clean(el.placeholder || el.title || el.alt || el.innerText || el.getAttribute("name") || "");
    };
    const isPassword = (el) => el.tagName === "INPUT" && (el.type || "").toLowerCase() === "password";

    const SELECTOR = [
        "a[href]", "button", "input:not([type=hidden])", "select", "textarea", "summary",
        "[role=button]", "[role=link]", "[role=checkbox]", "[role=radio]", "[role=tab]",
        "[role=menuitem]", "[role=option]", "[role=textbox]", "[role=searchbox]", "[role=combobox]",
        "[role=switch]", "[contenteditable=''], [contenteditable=true]"
    ].join(",");

    // Document order, through open shadow roots.
    const collect = (root, out) => {
        for (const el of root.querySelectorAll(SELECTOR)) out.push(el);
        for (const host of root.querySelectorAll("*")) if (host.shadowRoot) collect(host.shadowRoot, out);
        return out;
    };

    const collectPasswords = (root, out) => {
        for (const el of root.querySelectorAll("input[type=password]")) out.push(el);
        for (const host of root.querySelectorAll("*")) if (host.shadowRoot) collectPasswords(host.shadowRoot, out);
        return out;
    };

    const describeForm = (form) => {
        if (!form) return null;
        const submit = form.querySelector("button[type=submit], button:not([type]), input[type=submit], input[type=image]");
        return {
            method: (form.getAttribute("method") || "get").toLowerCase(),
            action: form.action || "",
            has_password: !!form.querySelector("input[type=password]"),
            is_search: form.getAttribute("role") === "search" || !!form.querySelector("input[type=search]"),
            submit_text: labelOf(submit)
        };
    };

    const stale = { ok: false, error: "stale_ref" };

    switch (arg.op) {
    case "list": {
        const items = [];
        for (const el of collect(document, [])) {
            if (items.length >= arg.limit) break;
            if (!visible(el)) continue;
            const item = { ref: refFor(el), role: roleOf(el), name: labelOf(el), in_viewport: inViewport(el) };
            const tag = el.tagName.toLowerCase();
            if (tag === "a" && el.href) item.href = el.href;
            if (tag === "input" || tag === "textarea" || tag === "select") {
                if (el.type) item.type = el.type.toLowerCase();
                // Never a password's value; everything else, so the agent can
                // see what it typed.
                if (!isPassword(el) && el.type !== "checkbox" && el.type !== "radio") item.value = clean(el.value, 200);
            }
            if (el.type === "checkbox" || el.type === "radio") item.checked = !!el.checked;
            if (el.disabled) item.disabled = true;
            items.push(item);
        }
        return { ok: true, url: location.href, title: document.title, elements: items, truncated: items.length >= arg.limit };
    }
    case "describe": {
        const el = lookup(arg.ref);
        if (!el) return stale;
        const form = el.form || el.closest("form");
        const submitter = el.matches("button:not([type]), button[type=submit], input[type=submit], input[type=image]");
        return {
            ok: true, role: roleOf(el), name: labelOf(el), tag: el.tagName.toLowerCase(),
            type: (el.type || "").toLowerCase(), is_password: isPassword(el),
            is_submit: !!(form && submitter), href: el.href || null,
            form: describeForm(form), host: location.host,
            // Script-driven sign-ins (no <form>, a "Next" button) still have
            // a password field the user has filled: anything clicked or
            // submitted then may send it.
            password_filled: collectPasswords(document, []).some(i => i.value.length > 0)
        };
    }
    case "click": {
        const el = lookup(arg.ref);
        if (!el) return stale;
        el.scrollIntoView({ block: "center", inline: "center" });
        if (el.focus) el.focus({ preventScroll: true });
        const r = el.getBoundingClientRect();
        const at = { bubbles: true, cancelable: true, composed: true, view: window, button: 0,
                     clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
        el.dispatchEvent(new PointerEvent("pointerdown", at));
        el.dispatchEvent(new MouseEvent("mousedown", at));
        el.dispatchEvent(new PointerEvent("pointerup", at));
        el.dispatchEvent(new MouseEvent("mouseup", at));
        el.click();
        return { ok: true };
    }
    case "type": {
        const el = lookup(arg.ref);
        if (!el) return stale;
        if (isPassword(el)) return { ok: false, error: "password_field" };
        el.scrollIntoView({ block: "center" });
        if (el.focus) el.focus({ preventScroll: true });
        if (el.tagName === "SELECT") {
            const want = arg.text.trim().toLowerCase();
            const option = [...el.options].find(o => o.value.toLowerCase() === want || clean(o.text).toLowerCase() === want);
            if (!option) return { ok: false, error: "no_such_option", options: [...el.options].map(o => clean(o.text, 60)).slice(0, 50) };
            el.value = option.value;
            el.dispatchEvent(new Event("input", { bubbles: true }));
            el.dispatchEvent(new Event("change", { bubbles: true }));
        } else if (el.isContentEditable) {
            if (arg.clear) {
                const range = document.createRange();
                range.selectNodeContents(el);
                const sel = getSelection(); sel.removeAllRanges(); sel.addRange(range);
            }
            document.execCommand("insertText", false, arg.text);
        } else if ("value" in el) {
            // The prototype's setter, as the password filler does: React's
            // value tracker swallows a plain `el.value =`.
            const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
            setter.call(el, arg.clear ? arg.text : el.value + arg.text);
            el.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: arg.text }));
            el.dispatchEvent(new Event("change", { bubbles: true }));
        } else {
            return { ok: false, error: "not_editable" };
        }
        if (arg.submit) {
            const form = el.form || el.closest("form");
            if (form) {
                if (form.requestSubmit) form.requestSubmit(); else form.submit();
            } else {
                for (const type of ["keydown", "keypress", "keyup"]) {
                    el.dispatchEvent(new KeyboardEvent(type, { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true, composed: true }));
                }
            }
        }
        return { ok: true, value: isPassword(el) ? "" : clean(el.value ?? el.innerText, 200) };
    }
    case "scroll": {
        if (arg.ref) {
            const el = lookup(arg.ref);
            if (!el) return stale;
            el.scrollIntoView({ block: "center" });
        } else {
            window.scrollBy({ top: arg.pages * innerHeight, behavior: "instant" });
        }
        const max = Math.max(0, document.documentElement.scrollHeight - innerHeight);
        return { ok: true, scroll_y: Math.round(scrollY), max_scroll_y: Math.round(max) };
    }
    case "find": {
        const text = (document.body || document.documentElement).innerText || "";
        return { ok: true, found: text.toLowerCase().includes(arg.text.toLowerCase()) };
    }
    }
    return { ok: false, error: "unknown_op" };
    """#
}
