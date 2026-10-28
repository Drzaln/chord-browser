import Foundation
import WebKit

/// A Chrome Web Store page asking Chord to install the extension it shows.
///
/// The store detects a non-Chrome browser: it covers the page with a "Switch to
/// Chrome" banner and leaves its install button disabled. The page script hides
/// that furniture and puts an "Add to Chord" button in the store's own place.
/// The id comes from the tab's address, never from the page, and the normal
/// install path (signature check, prepared bundle, enable) still runs.
public protocol ChromeStoreRelayDelegate: AnyObject {
    @MainActor func installFromStorePage(id: String)
}

@MainActor
final class ChromeStoreRelayHandler: NSObject, WKScriptMessageHandler {
    static let name = "chordStore"
    var delegate: ChromeStoreRelayDelegate?

    nonisolated func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let id = body["add"] as? String
        else { return }
        MainActor.assumeIsolated {
            delegate?.installFromStorePage(id: id)
        }
    }
}

/// Quietens the store's non-Chrome furniture and relays its install button.
enum ChromeWebStoreRelay {
    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true
        )
    }

    static let script = """
    (function () {
      if (location.hostname !== 'chromewebstore.google.com' || window.__chordStore) return;
      window.__chordStore = true;

      function pageID() {
        var m = location.pathname.match(/\\/detail\\/(?:[^\\/]+\\/)?([a-p]{32})/);
        return m ? m[1] : null;
      }

      function theirs() {
        var buttons = document.querySelectorAll('button[disabled]');
        for (var i = 0; i < buttons.length; i++) {
          var b = buttons[i];
          if (!b.dataset.chord && /chrome/i.test(b.textContent || '')) return b;
        }
        return null;
      }

      function bannerOf(button) {
        var box = null, up = button.parentElement;
        while (up && up !== document.body) {
          if (up.querySelector('button[disabled], button[data-chord]')) break;
          if ((up.innerText || '').length > 160) break;
          box = up;
          up = up.parentElement;
        }
        return box;
      }

      function hideBanner() {
        var cards = document.querySelectorAll('[role="dialog"]');
        for (var c = 0; c < cards.length; c++) {
          if (!cards[c].dataset.chord && cards[c].querySelector('img[src*="productlogos/chrome"]')) {
            cards[c].style.display = 'none';
            cards[c].dataset.chord = 'promo';
          }
        }
        var buttons = document.querySelectorAll('button:not([disabled])');
        for (var i = 0; i < buttons.length; i++) {
          var b = buttons[i];
          if (b.dataset.chord || !/chrome/i.test(b.getAttribute('aria-label') || '')) continue;
          var box = bannerOf(b);
          if (box && !box.dataset.chord) {
            box.style.display = 'none';
            box.dataset.chord = 'banner';
          }
        }
      }

      function label(button, text) {
        var walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
        var node, last = null;
        while ((node = walker.nextNode())) { if (node.nodeValue.trim()) last = node; }
        if (last) last.nodeValue = text; else button.textContent = text;
      }

      function mend() {
        hideBanner();
        var id = pageID();
        if (!id) return;
        var original = theirs();
        if (original && original.parentNode) {
          var ours = original.cloneNode(true);
          ['disabled', 'jsaction', 'jscontroller', 'jsname', 'jslog', 'aria-describedby']
            .forEach(function (name) { ours.removeAttribute(name); });
          ours.dataset.chord = 'add';
          original.dataset.chord = 'theirs';
          original.style.display = 'none';
          original.parentNode.insertBefore(ours, original.nextSibling);
          label(ours, 'Add to Chord');
        }
        var mine = document.querySelectorAll('button[data-chord="add"]');
        for (var i = 0; i < mine.length; i++) {
          if (!mine[i].dataset.chordBound) {
            mine[i].dataset.chordBound = '1';
            mine[i].addEventListener('click', function (e) {
              e.preventDefault();
              e.stopImmediatePropagation();
              if (this.disabled) return;
              this.disabled = true;
              label(this, 'Adding…');
              try {
                window.webkit.messageHandlers.chordStore.postMessage({ add: id });
              } catch (x) {}
            }, true);
          }
        }
      }

      var queued = false;
      new MutationObserver(function () {
        if (queued) return;
        queued = true;
        setTimeout(function () { queued = false; mend(); }, 60);
      }).observe(document.documentElement, { childList: true, subtree: true });
      mend();
    })();
    """
}
