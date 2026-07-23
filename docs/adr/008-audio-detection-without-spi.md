# 008 — Audio detection by user script, not SPI

**Status:** accepted (M3)

BROWSER_SPEC 4.3 requires the ephemeral sweep to exempt tabs that are playing
audio. There is no public API for this. `WKWebView` exposes
`cameraCaptureState` and `microphoneCaptureState`, which are about *capture*,
not playback. The property every other browser reaches for, `_isPlayingAudio`,
is SPI: it does not appear in the SDK headers, and 11 rules out shipping against
API we cannot see there.

The options were to use the SPI anyway, drop the exemption, or observe playback
from inside the page. We observe from inside the page.

`MediaActivityMonitor` injects a user script at document start into every frame.
It listens in the capture phase for `play`, `pause`, `ended`, `volumechange`,
and `emptied` — media events do not bubble, so capture phase is required — and
posts a message when the set of audible elements changes. "Audible" means not
paused, not muted, and volume above zero, which is closer to the user's idea of
"making noise" than a raw playing flag would be.

The trade-offs, stated plainly. This does not see audio from Web Audio API
nodes that never touch a media element, so a synthesised-audio page could in
principle be swept while making noise. It also costs a script message handler
per web view — one of the two classic leak sources named in 6.7 — so the handler
is explicitly removed in `LiveWebView.tearDown()` rather than left to deinit.

The handler is installed on a **per-view** `WKUserContentController`, not on the
shared configuration template. `WKWebViewConfiguration.copy()` does not
deep-copy the content controller, so sharing it means adding the same handler
name twice, which throws `NSInvalidArgumentException` and takes the app down on
the second tab. That bug was written, shipped into the build, and caught by the
end-to-end test — not by any unit test, because no unit test creates two real
web views through the engine.
