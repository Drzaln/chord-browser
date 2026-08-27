import WebKit

/// Captures a pane's DRM / streaming failure surface from inside the page
/// (non-spec: user-requested), for the DRM Diagnostics panel.
///
/// WebKit reports no playback error to the host — a Netflix page that refuses a
/// stream shows its own app-level error (2003 etc.), which the DOM's
/// `MediaError` never surfaces either. What *is* observable from inside the page
/// is the media element's own error (a decode/network/src failure) and the
/// `encrypted` event that marks EME/DRM actually being used. That is the
/// engine-level truth the panel can show without reading Netflix's private UI.
///
/// Installed per-view like the other monitors, with the standard
/// `window.__chordDrm` singleton guard because `atDocumentStart` can run more
/// than once per document.
enum DRMDiagnosticsMonitor {
    static let messageName = "chordDRMDiagnostics"

    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: Self.source, injectionTime: .atDocumentStart, forMainFrameOnly: false
        )
    }

    private static let source = """
    (function () {
      if (window.__chordDrm) return;
      window.__chordDrm = { eme: false };

      function post(payload) {
        try { window.webkit.messageHandlers.\(messageName).postMessage(payload); }
        catch (e) {}
      }

      // A media element raised an error (MEDIA_ERR_*). Capture phase, so a child
      // element's error still counts.
      document.addEventListener("error", function (e) {
        var t = e.target;
        if (!t || !(t.tagName === "VIDEO" || t.tagName === "AUDIO") || !t.error) return;
        var code = t.error.code;
        var name = t.error.name || "";
        post({ kind: "media", text: "code " + code + (name ? " (" + name + ")" : "") });
      }, true);

      // The `encrypted` event is WebKit telling the page it needs a key: proof a
      // DRM/EME session is actually in play on this page.
      document.addEventListener("encrypted", function (e) {
        if (window.__chordDrm.eme) return;
        window.__chordDrm.eme = true;
        post({ kind: "eme" });
      }, true);
    })();
    """

    /// `{kind:"media", text:"code 3 (MEDIA_ERR_DECODE)"}` → the display string.
    static func mediaError(from body: Any) -> String? {
        guard let dict = body as? [String: Any],
            dict["kind"] as? String == "media",
            let text = dict["text"] as? String, !text.isEmpty
        else { return nil }
        return text
    }

    /// `{kind:"eme"}` marks that an EME session has been started.
    static func isEME(_ body: Any) -> Bool {
        (body as? [String: Any])?["kind"] as? String == "eme"
    }
}
