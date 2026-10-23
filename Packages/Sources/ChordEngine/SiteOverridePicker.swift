import Foundation
import WebKit

/// The element picker for site overrides (non-spec: user-requested, ADR 024).
///
/// Unlike the monitors this is not an injected user script: the user asks to
/// pick an element on a page that is *already loaded*, so a document-start
/// script would not run until the next navigation. The source below is evaluated
/// into the live page instead, which also means it can be cancelled and removed
/// cleanly.
///
/// The overlay is main-frame only, so it cannot reach into a cross-origin iframe
/// — the YouTube player, an embedded editor. That is a documented limitation,
/// not a bug: WebKit gives no way to attach a picker across origins.
enum SiteOverridePicker {
    static let messageName = "chordSiteOverridePick"

    /// The JS installed into the page. Reports `{selector, host}` on a pick and
    /// `{cancel: true}` on Escape.
    static let source = """
    (function () {
        var handler = window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.\(messageName);
        if (!handler) { return; }
        if (window.__chordPickerActive) { return; }
        window.__chordPickerActive = true;

        var box = document.createElement('div');
        box.style.cssText = 'position:fixed;z-index:2147483647;border:2px solid #4c8bf5;'
            + 'background:rgba(76,139,245,0.18);border-radius:3px;pointer-events:none;display:none;';
        var label = document.createElement('div');
        label.style.cssText = 'position:fixed;z-index:2147483647;background:#1b1b1b;color:#fff;'
            + 'font:11px -apple-system,sans-serif;padding:2px 6px;border-radius:3px;'
            + 'pointer-events:none;display:none;max-width:60vw;overflow:hidden;'
            + 'text-overflow:ellipsis;white-space:nowrap;';
        var root = document.documentElement;
        root.appendChild(box);
        root.appendChild(label);

        function escapeIdentifier(value) {
            if (window.CSS && CSS.escape) { return CSS.escape(value); }
            return value.replace(/[^a-zA-Z0-9_-]/g, '\\\\$&');
        }

        // The shortest selector that still identifies the element: an id, a
        // stable data attribute, then a bounded nth-of-type path.
        function selectorFor(element) {
            if (element.id) {
                var byId = '#' + escapeIdentifier(element.id);
                if (document.querySelectorAll(byId).length === 1) { return byId; }
            }
            var attributes = ['data-testid', 'data-test', 'data-qa', 'aria-label'];
            for (var i = 0; i < attributes.length; i++) {
                var value = element.getAttribute && element.getAttribute(attributes[i]);
                if (!value) { continue; }
                var candidate = element.tagName.toLowerCase()
                    + '[' + attributes[i] + '="' + value.replace(/"/g, '\\\\"') + '"]';
                if (document.querySelectorAll(candidate).length === 1) { return candidate; }
            }
            var parts = [];
            var node = element;
            while (node && node.nodeType === 1 && node !== root && parts.length < 5) {
                var part = node.tagName.toLowerCase();
                var parent = node.parentElement;
                if (parent) {
                    var sameTag = Array.prototype.filter.call(parent.children, function (child) {
                        return child.tagName === node.tagName;
                    });
                    if (sameTag.length > 1) {
                        part += ':nth-of-type(' + (sameTag.indexOf(node) + 1) + ')';
                    }
                }
                parts.unshift(part);
                node = parent;
            }
            return parts.join(' > ');
        }

        function cleanup() {
            window.__chordPickerActive = false;
            box.remove();
            label.remove();
            document.removeEventListener('mousemove', onMove, true);
            document.removeEventListener('click', onClick, true);
            document.removeEventListener('keydown', onKey, true);
        }

        function describe(element) {
            var name = element.tagName.toLowerCase();
            if (element.id) { name += '#' + element.id; }
            else if (element.classList && element.classList.length) {
                name += '.' + Array.prototype.slice.call(element.classList, 0, 2).join('.');
            }
            return name;
        }

        function onMove(event) {
            var element = event.target;
            if (!element || element === box || element === label || element.nodeType !== 1) {
                return;
            }
            var rect = element.getBoundingClientRect();
            box.style.display = 'block';
            box.style.left = rect.left + 'px';
            box.style.top = rect.top + 'px';
            box.style.width = rect.width + 'px';
            box.style.height = rect.height + 'px';
            label.style.display = 'block';
            label.textContent = describe(element);
            label.style.left = Math.max(4, rect.left) + 'px';
            label.style.top = Math.max(4, rect.top - 22) + 'px';
        }

        function onClick(event) {
            var element = event.target;
            if (!element || element.nodeType !== 1) { return; }
            event.preventDefault();
            event.stopPropagation();
            var selector = selectorFor(element);
            cleanup();
            handler.postMessage({ selector: selector, host: location.hostname });
        }

        function onKey(event) {
            if (event.key !== 'Escape') { return; }
            event.preventDefault();
            cleanup();
            handler.postMessage({ cancel: true });
        }

        document.addEventListener('mousemove', onMove, true);
        document.addEventListener('click', onClick, true);
        document.addEventListener('keydown', onKey, true);
    })();
    """

    /// Reads a pick result out of a message body. Nil when the body is not a
    /// dictionary this picker wrote.
    static func result(from body: Any) -> (selector: String?, host: String?, cancelled: Bool)? {
        guard let dictionary = body as? [String: Any] else { return nil }
        if dictionary["cancel"] as? Bool == true { return (nil, nil, true) }
        guard let selector = dictionary["selector"] as? String, !selector.isEmpty else {
            return nil
        }
        return (selector, dictionary["host"] as? String, false)
    }
}
