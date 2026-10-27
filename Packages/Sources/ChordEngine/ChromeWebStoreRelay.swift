import Foundation
import WebKit

/// Quietens the Chrome Web Store's "this isn't Chrome" furniture.
///
/// The store covers its page with a "Switch to Chrome" banner/card and leaves
/// its install button disabled for non-Chrome browsers. Chord installs from
/// the store already — Settings accepts the link or id — so the banner and card
/// are hidden and the grey button points at the real path instead of pretending
/// to work.
///
/// Page-only and idempotent: it looks for the store's own disabled button and
/// the Chrome logo in a dialog, never for generated class names.
enum ChromeWebStoreRelay {
    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    static let script = """
    (function () {
      if (location.hostname !== 'chromewebstore.google.com' || window.__chordStore) return;
      window.__chordStore = true;

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
          var box = null, up = b.parentElement;
          while (up && up !== document.body) {
            if (up.querySelector('button[disabled], button[data-chord]')) break;
            if ((up.innerText || '').length > 160) break;
            box = up;
            up = up.parentElement;
          }
          if (box && !box.dataset.chord) {
            box.style.display = 'none';
            box.dataset.chord = 'banner';
          }
        }
      }

      function relabel() {
        var buttons = document.querySelectorAll('button[disabled]');
        for (var i = 0; i < buttons.length; i++) {
          var b = buttons[i];
          if (b.dataset.chord || !/chrome/i.test(b.textContent || '')) continue;
          b.dataset.chord = 'theirs';
          var walker = document.createTreeWalker(b, NodeFilter.SHOW_TEXT);
          var node, last = null;
          while ((node = walker.nextNode())) { if (node.nodeValue.trim()) last = node; }
          if (last) last.nodeValue = 'Use Add to Chord above';
        }
      }

      function mend() { hideBanner(); relabel(); }
      mend();
      new MutationObserver(mend).observe(document.documentElement, {
        childList: true, subtree: true, characterData: true
      });
    })();
    """
}
