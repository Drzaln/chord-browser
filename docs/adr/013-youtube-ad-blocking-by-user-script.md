# 013 — YouTube ad blocking by user script, not the content blocker

**Status:** accepted

The most-requested addition after the network content blocker was blocking
YouTube and YouTube Music ads. The content blocker (`ContentBlocker`, §4.8, ADR
008 is its sibling) cannot do it, and no amount of filter-list tuning will change
that: it matches on URLs, and YouTube streams its ads from the *same* host
(`*.googlevideo.com`) through the *same* `<video>` element as real content. There
is no ad request to drop and no distinct element to hide by URL. This is the same
reason uBlock Origin ships a *script* for YouTube, not a filter list.

So YouTube blocking is a **separate, page-side user script** (`YouTubeAdBlocker`),
in the same family as the other in-page monitors, not part of the
`WKContentRuleList` pipeline. It:

- guards to `*.youtube.com` / `*.youtube-nocookie.com` (covers `music.youtube.com`
  and `/embed/` iframes; injected `forMainFrameOnly: false`),
- installs CSS that hides static ad surfaces (mastheads, promoted rows, in-feed
  and YouTube Music ad slots),
- polls the player every 250 ms and, while an ad is showing, clicks _Skip_ if
  present and otherwise both seeks the ad to its end *and* runs it at 10× speed.
  YouTube is an SPA, so a poll — not a one-shot — is what survives navigation
  between videos.

A seek to `video.duration` alone does **not** reliably remove *unskippable* ads:
many ads clamp or ignore seeks, and the ad module tracks completion by its own
timer, not the video's `currentTime`. That timer is tied to media playback, so
bumping `playbackRate` drains it in a fraction of a second — this is what
actually clears unskippable ads. The ad and the real video are one `<video>`
element, so the bumped rate must never leak into content: it is restored to 1×
on the first non-ad tick and on the media's `ended` event (verified: after a
forced bump, the next no-ad tick restored 1×).

Two deliberate choices. It **does not mute**: mute is owned by
`AudioMuteController`, and fast-forwarding ends the ad fast enough that muting is
unnecessary and would only fight that controller. And it needs **no message
handler** — it is entirely page-side, so unlike `MediaActivityMonitor` /
`ScreenShareMonitor` there is nothing to remove in `LiveWebView.tearDown()` and
no leak surface. A `window.__chordYTAdBlock` singleton guard makes re-injection
(`atDocumentStart` can run more than once) idempotent.

Trade-off, stated plainly: this is cat-and-mouse. YouTube renames classes and
adds anti-adblock walls, so the selectors are best-effort and are the most likely
thing to need maintenance. It is not a reimplementation of uBlock Origin's YouTube
scriptlets, and it can miss a new ad format until updated. Verified working end
to end against a live pre-roll ad: the poll clicked through to the skippable point
and the content video began. The alternative — telling users to install an
extension — does not work at all here (Apple's `WKWebExtension` caps rules and
offers no scriptlet injection), which is the whole reason this is built in.
