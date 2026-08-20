import Foundation
import WebKit

/// Pauses a page's media when a sleep timer fires (non-spec: user-requested).
///
/// The sleep timer's *deadline* is owned by the engine, not this page — see
/// `WebKitEngine.setSleepTimer`. A `setTimeout` here would be throttled in a
/// background tab and wiped by a reload, which are exactly the moments a sleep
/// timer must not die, so this script supplies only the one primitive the
/// engine needs at fire time: pause every media element. YouTube and YouTube
/// Music both keep their audio in real `<video>`/`<audio>` elements, so pausing
/// them is all it takes. Like `AudioMuteController` this is generic and works
/// on any page; those are the sites it exists for.
enum SleepTimerController {
    /// The JS entry point the engine calls when the timer fires.
    static let pauseAllFunction = "window.__chordSleepTimerPauseAll"

    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private static let source = """
    (function () {
        window.__chordSleepTimerPauseAll = function () {
            var media = document.querySelectorAll('audio, video');
            for (var i = 0; i < media.length; i++) {
                try { media[i].pause(); } catch (e) {}
            }
        };
    })();
    """
}
