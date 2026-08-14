---
name: chord-browser-youtube-ads
description: Periodic compatibility checks and selector upkeep for the built-in YouTube ad blocker in Chord Browser. YouTube changes DOM class names, player states, skip-button markup, and anti-adblock walls constantly, so the injected script in YouTubeAdBlocker.swift goes stale. Use when YouTube ads start appearing again, when asked to check/verify/update YouTube ad blocking, when comparing against upstream filter lists, or when touching anything in YouTubeAdBlocker.swift.
---

# YouTube Ad Blocker Compatibility Check

The ad blocker is a single injected user script (`Packages/Sources/BrowserEngine/YouTubeAdBlocker.swift`) that is **inherently a cat-and-mouse game** — YouTube changes selectors on its own schedule, and there is no URL filter that can replace the script (ads share the same host and the same `<video>` as content). This skill is the recurring maintenance loop that keeps it working.

---

## When to Check

- **Routine cadence: every ~2 weeks.** Treat it like the quarterly Safari UA check in the maintenance skill, but faster.
- **Trigger: a user reports ads showing** (either static ads visible, or video ads playing to completion instead of being skipped).
- **Trigger: a visible YouTube UI rollout.** Major player redesigns, "ad blockers are not allowed" walls, or new skip-button styles.
- **Trigger: upstream churn.** EasyList / uBlock Origin / AdGuard ship a YouTube rule or scriptlet change (see Layer 1).

Open a tracking issue for each run with `bd`, and close it when the check (or update) is done:

```bash
bd create "YouTube ad blocker: monthly compatibility check" -t task -p 3 --json
```

---

## The Current Surface (what can go stale)

All of this lives in `YouTubeAdBlocker.swift`. When a check runs, compare **each** of these against the live DOM:

| What | Current value |
|---|---|
| Host guard | `youtube.com`, `youtube-nocookie.com` (any subdomain, incl. `music.` and `m.`) |
| Player root | `.html5-video-player` |
| Ad-playing states | classes `ad-showing`, `ad-interrupting` on the player root, plus `.ytp-ad-player-overlay` being visible |
| Skip buttons | `.ytp-ad-skip-button`, `.ytp-ad-skip-button-modern`, `.ytp-skip-ad-button`, `.ytp-ad-skip-button-container button` |
| Hidden surfaces (CSS) | `.video-ads`, `.ytp-ad-module`, `.ytp-ad-overlay-container`, `.ytp-ad-overlay-slot`, `.ytp-suggested-action`, `#masthead-ad`, `ytd-ad-slot-renderer`, `ytd-display-ad-renderer`, `ytd-promoted-sparkles-web-renderer`, `ytd-promoted-video-renderer`, `ytd-in-feed-ad-layout-renderer`, `ytd-banner-promo-renderer`, `ytmusic-ad-slot-renderer`, `.ytmusic-ad-slot-renderer` |
| Anti-adblock wall | **dismantled by JS**, not just hidden. CSS hides `tp-yt-paper-dialog:has(ytd-enforcement-message-view-model)` as a fallback; a `MutationObserver` (`dismantleEnforcementWall`) removes `ytd-enforcement-message-view-model` (climbing to its `TP-YT-PAPER-DIALOG` host), drops a visible `tp-yt-iron-overlay-backdrop`, resets `documentElement`/`body` `overflow`, and best-effort resumes the paused player |
| Skip/seek behavior | tick every 250 ms; seek to `duration` only when `0 < duration <= 60`; re-assert `playbackRate = 10` on **every** tick; restore to 1x the moment the ad ends |

Registered in `WebKitEngine.swift:214` via `controller.addUserScript(YouTubeAdBlocker.makeUserScript())`, injected `.atDocumentStart`, **all frames** (embeds and `music.youtube.com` are separate documents). Never change that injection shape without re-reading why it is there.

---

## Layer 1 — Upstream Signal (cheap, do first)

When upstream filter projects update their YouTube rules, ours usually needs to follow:

```bash
# uBlock Origin's filter sets — YouTube scriptlets + cosmetic rules
git clone --depth 1 https://github.com/gorhill/uAssets /tmp/uAssets 2>/dev/null
rg -n -i "youtube" /tmp/uAssets/filters/ /tmp/uAssets/scriptlets/ | rg -i "ad|ytp|skip" | head -60

# EasyList — cosmetic + hiding rules for youtube.com
curl -sL https://raw.githubusercontent.com/easylist/easylist/master/easylist/easylist.txt \
  | rg -i "youtube" | rg -i "ytp-ad|ad-slot|masthead|display-ad|video-ads" | head -60
```

Interpretation: if upstream has renamed `.ytp-ad-skip-button*`, introduced a new ad container (e.g. a renamed `ytd-ad-slot-renderer`), or added a new enforcement-wall selector, port the change into our CSS list / `SKIP` list. uBlock's *script* approach (a `youtube-ad-block` scriptlet) mirrors ours and is the closest model — check its selectors too.

Do **not** paste upstream filters wholesale: our script is a hand-rolled CSS + player-state poll, not a rule-list engine. Port selectors, not rules.

---

## Layer 2 — Inspect the Live Player DOM

Ground truth is YouTube's real DOM in the running app. Two ways to run the probe:

### Probe snippet

Paste this into a page context on a YouTube watch page (see A or B below). It reports exactly which of our selectors still match, so a break is a one-line diagnosis:

```js
(() => {
  const player = document.querySelector('.html5-video-player');
  const css = ['.video-ads','.ytp-ad-module','.ytp-ad-overlay-container',
    '.ytp-ad-overlay-slot','.ytp-suggested-action','#masthead-ad',
    'ytd-ad-slot-renderer','ytd-display-ad-renderer',
    'ytd-promoted-sparkles-web-renderer','ytd-promoted-video-renderer',
    'ytd-in-feed-ad-layout-renderer','ytd-banner-promo-renderer',
    'ytmusic-ad-slot-renderer','.ytmusic-ad-slot-renderer',
    'tp-yt-paper-dialog:has(ytd-enforcement-message-view-model)'];
  const skip = ['.ytp-ad-skip-button','.ytp-ad-skip-button-modern',
    '.ytp-skip-ad-button','.ytp-ad-skip-button-container button'];
  const overlay = player && player.querySelector('.ytp-ad-player-overlay');
  const backdrop = document.querySelector('tp-yt-iron-overlay-backdrop, iron-overlay-backdrop');
  return JSON.stringify({
    playerFound: !!player,
    adState: player ? {
      adShowing: player.classList.contains('ad-showing'),
      adInterrupting: player.classList.contains('ad-interrupting'),
      overlayVisible: !!(overlay && overlay.getClientRects().length > 0)
    } : null,
    wall: {
      enforcementModel: !!document.querySelector('ytd-enforcement-message-view-model'),
      backdropVisible: !!(backdrop && backdrop.getClientRects().length > 0),
      bodyScrollLocked: document.body.style.overflow === 'hidden'
        || document.documentElement.style.overflow === 'hidden'
    },
    videosOnPage: document.querySelectorAll('video').length,
    skipMatches: skip.map(s => [s, !!document.querySelector(s)]),
    cssMatches: css.map(s => [s, !!document.querySelector(s)]),
    styleInjected: !!document.getElementById('__chord-yt-adblock')
  });
})()
```

**How to read it:**
- `playerFound:false` → the player root class changed. Everything else is moot.
- `adState` all `false` *while an ad is on screen* → the ad-state detection broke; add the new class/overlay signal.
- `skipMatches` with a live skip button showing `false` → new skip-button markup; update `SKIP`.
- `cssMatches` all `false` for a *visible* ad slot (e.g. masthead ad shows but `#masthead-ad` is gone) → the hide list drifted.
- `styleInjected:false` → the script isn't running at all (injection regression), not a selector problem.
- `wall` all `true` *while the page is frozen* → the wall watch failed: the observer or `dismantleEnforcementWall` is missing, or the wall/backdrop selector renamed. The page freezing (no scroll/click after an ad) is *this* state, not a web-view bug.

### A — Interactive (accurate, needs the real session)

1. Temporarily enable WebKit's developer extras in `WebKitEngine.swift:358` (`configurationTemplate`), run the app, then **revert the line and don't commit it**:
   ```swift
   config.preferences.setValue(true, forKey: "developerExtrasEnabled")
   ```
2. Build and launch the app, open a YouTube watch page that shows ads.
3. Safari → **Develop** → the machine → Chord → **Show Web Inspector**, switch to the **Console**.
4. Paste the probe while an ad is playing (or right after, while the ad DOM is live) and read the JSON.

### B — Scripted harness (reproducible, structural only)

The maintenance skill's throwaway-script pattern, extended: a `swift file.swift` outside the repo that builds a `WKWebView`, reads the **current** blocker JS out of the Swift source, injects it, loads a watch page, and prints the probe JSON after a delay. Caveats: it has a fresh cookie store, so it is a **signed-out** session — good for structural selector checks, unreliable for actually playing ads.

```swift
// /tmp/ytprobe.swift  — run: swift /tmp/ytprobe.swift
import Foundation
import WebKit

let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!

// Pull the blocker source out of YouTubeAdBlocker.swift (best-effort regex).
let src = try! String(contentsOfFile:
    "Packages/Sources/BrowserEngine/YouTubeAdBlocker.swift", encoding: .utf8)
let js = src
    .split(separator: "\n").drop(while: { !$0.contains("private static let source") })
    .dropFirst().dropLast().joined(separator: "\n")
    .replacingOccurrences(of: "\\\"", with: "\"")

let config = WKWebViewConfiguration()
config.preferences.setValue(true, forKey: "developerExtrasEnabled")
let controller = WKUserContentController()
controller.addUserScript(WKUserScript(
    source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
config.userContentController = controller
let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1280, height: 800),
                        configuration: config)
webView.load(URLRequest(url: url))
RunLoop.main.run(until: Date().addingTimeInterval(35))

// The probe from above, as a single expression (see the "Probe snippet" section).
let probe = #"""
(() => {
  const player = document.querySelector('.html5-video-player');
  return JSON.stringify({
    playerFound: !!player,
    adShowing: player ? player.classList.contains('ad-showing') : null,
    adInterrupting: player ? player.classList.contains('ad-interrupting') : null,
    skipButtons: !!document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button'),
    styleInjected: !!document.getElementById('__chord-yt-adblock')
  });
})()
"""#
webView.evaluateJavaScript(probe) { value, error in
    print(error.map(String.init) ?? (value as? String ?? "no result"))
    exit(0)
}
RunLoop.main.run()
```

Run from the repo root. Adjust the delay (e.g. 35 s) so a pre-roll has time to fire.

---

## Layer 3 — Visual Smoke (ground truth)

`os.Logger` is unreadable on this machine, but AppLog mirrors every line to
`Application Support/Browser/Logs/browser.log` (the `engine` category logs
content-process deaths and navigation failures, which a screenshot can't show).
Confirm the ad surfaces with screenshots in the real app:

```bash
screencapture -x -o /tmp/yt-watch.png     # a video with pre-roll ads
screencapture -x -o /tmp/yt-home.png      # homepage — in-feed + masthead ads
screencapture -x -o /tmp/ytm.png          # music.youtube.com — ad slots
```

Verify **each** of these is clean:
- No pre-roll/mid-roll video ad plays (player jumps straight to content, no black video-ad span)
- No skip button ever visible, no "ad will play in 5" countdown
- No overlay/banner ad over the bottom of the player
- No masthead ad, no promoted rows, no in-feed ad slots on the homepage
- No "Ad blockers are not allowed" wall blocking playback
- Playback rate is normal (1x) during content — the blast must never leak into content
- The page stays interactive after an ad: scroll past the player and click the comments *after* an ad has been skipped/blasted — a frozen page means the wall's backdrop/`overflow` lock was left behind

---

## What to Change When Something Broke

All edits stay in `Packages/Sources/BrowserEngine/YouTubeAdBlocker.swift`:

1. **Static ads visible** → update the `css` array (rename/replace dead selectors with the live ones from Layer 2).
2. **Video ads not skipped / not fast-forwarded** →
   - Skip button lives elsewhere → update `SKIP`.
   - Skip button clicks are ignored → the button may be a custom element; check whether the fallback (seek + rate blast) still runs — it must, the early `return` after click was removed deliberately.
   - Rate blast is ignored → YouTube likely reset `playbackRate`; re-assert on every tick is already the design — if it regressed, restore it. If the ad is on a **separate `<video>`**, verify the "blast every `<video>`" loop is still there.
   - Ad no longer ends → check the `duration <= 60` seek guard: stitched/SSAI ads report content duration, and a full seek there would skip content instead.
3. **Playback blocked by an anti-adblock wall** → the wall is dismantled, not hidden: the observer removes `ytd-enforcement-message-view-model`, the visible `tp-yt-iron-overlay-backdrop`, and the `overflow` lock, then resumes the player. If the wall selector changed, update **both** the CSS fallback (`tp-yt-paper-dialog:has(...)`) and the JS selector in `dismantleEnforcementWall`. Do **not** revert to CSS-only hiding: the wall is a modal iron-overlay, so hiding its element leaves the overlay open underneath — a full-screen backdrop that swallows every pointer event plus a `body` overflow lock, i.e. the whole page freezes (no scroll, no click) after the ad.
4. **Page freezes after an ad ends (no scroll, no click)** → this is the wall's leftover backdrop/scroll-lock, not a native view problem. Verify the wall watch still runs: the `MutationObserver` on `document.documentElement` (`childList` + `subtree`) calling `dismantleEnforcementWall`, and that it removes the backdrop and restores `overflow`. Symptom almost always means the observer got dropped in a refactor, or the wall element moved outside `ytd-enforcement-message-view-model`.
5. **Mute only ever overrides *during* the ad** — the video is force-muted while
   an ad is up (`muteForAd`) and the saved `__chordPrevMuted` is restored with
   the rate (`restoreRate`). That saved value IS `AudioMuteController`'s applied
   state, so the user's own per-tab mute always survives. A regression here
   shows as content playing muted after an ad — check that both `muteForAd` and
   the restore path are still wired.

### Tests

`Packages/Tests/BrowserEngineTests/YouTubeAdBlockerTests.swift` asserts the injection shape (`.atDocumentStart`, all frames), anchors the source to `youtube`, `ad-showing`, and the `__chordYTAdBlock` singleton guard, checks the ad-mute save/restore (`video.muted = true`, `__chordAdMuted`, `__chordPrevMuted`), and anchors the wall handling (`ytd-enforcement-message-view-model`, `tp-yt-iron-overlay-backdrop`, `dismantleEnforcementWall`, `MutationObserver`). If a rewrite drops any of those anchors, update the test — but don't remove the anchors lightly; they're what make a refactor fail loudly.

```bash
swift test --package-path Packages --filter YouTubeAdBlockerTests
swift test --package-path Packages          # full suite, expect 512+
./scripts/prepush.sh                         # before any push
```

### Close the loop

Update the `bd` issue with what changed (or that nothing needed changing), and close it. Note the finding in the issue's description so the next check knows what was already looked at.

---

## Known Failure Modes (watch for these first)

| Symptom | Likely cause | Fix |
|---|---|---|
| Ads always play to completion | Rate blast dies (once-only guard regressed) or ad moved to a separate `<video>` | Re-assert rate every tick; blast all videos |
| Static ads visible | Hide-list selectors renamed | Port new selectors from Layer 2 / Layer 1 |
| Player blocked, "ad blockers not allowed" | Enforcement-wall selector renamed | Update wall selector in `dismantleEnforcementWall` **and** the CSS fallback |
| Page freezes after an ad (no scroll, no click) | Wall's iron-overlay backdrop + `overflow` lock left behind (CSS-only hiding, or wall watch dropped) | Keep the `MutationObserver` calling `dismantleEnforcementWall`; it must remove the backdrop and restore `overflow` |
| Content plays at 10x briefly | Rate not restored fast enough | `ended` listener + `!adShowing` restore are both required |
| Content plays **muted** after an ad | Ad-mute not restored (or a mid-ad mute toggle lost its saved value) | `restoreRate` must restore `__chordPrevMuted`; re-assert mute every tick |
| Ad audio blasts during fast-forward | `muteForAd` dropped or not wired into the tick | Call `muteForAd(video)` beside the rate blast each tick |
| Everything works on `youtube.com` but not embeds | Injection became main-frame-only | Keep `forMainFrameOnly: false` |

---

## Key File Locations

| What | Where |
|---|---|
| Ad blocker script | `Packages/Sources/BrowserEngine/YouTubeAdBlocker.swift` |
| Script registration | `Packages/Sources/BrowserEngine/WebKitEngine.swift:214` |
| Tests | `Packages/Tests/BrowserEngineTests/YouTubeAdBlockerTests.swift` |
| Full maintenance guide | `.agents/skills/chord-browser-maintenance/SKILL.md` |
