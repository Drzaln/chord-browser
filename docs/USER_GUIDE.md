# Chord Browser — User Guide

How to drive Chord Browser day-to-day: keyboard shortcuts, the command bar, Spaces,
split view, Little Chord, downloads, find-in-page, content blocking, and extensions.

This guide describes what is actually wired in the shipping app. Where a
capability exists in the engine but has no user-facing control yet, it says so
plainly.

---

## The basics

Chord opens with **one window**, and `Cmd+N` gives you another (see
[Windows](#windows)). The sidebar on the left holds the Space switcher,
the tab list, navigation controls, and any extension action buttons. Web content
sits in an inset card to the right. The sidebar and the frame around the card are
**frosted glass** — translucent `.ultraThinMaterial` tinted by the active Space's
color, blurring your desktop behind the window (the web page itself stays opaque).

- **Address / search:** press `Cmd+L` (or `Cmd+T`) to open the command bar, type
  a URL or a search query, and press Enter. Anything that isn't a recognisable
  URL is sent to **Google** as a search.
- **Back / forward:** `Cmd+[` and `Cmd+]`, or the chevrons in the sidebar.
- **Reload:** `Cmd+R`. While a page is loading the reload button becomes a stop
  button, and a thin progress bar runs under the address bar — or, when the
  sidebar is collapsed, along the top edge of the page.

When a page opens a new window — a `target="_blank"` link, or a site's **"Sign
in with Google"** popup (Shopee, etc.) — the new window becomes a tab. It is a
real popup under the hood, so the flow works the way the site expects: the
opening page keeps its `window.open()` reference, and the login popup **closes
its own tab** once you finish signing in instead of lingering.

---

## Keyboard shortcuts

### Tabs & navigation

| Shortcut         | Action                                                                        |
| ---------------- | ----------------------------------------------------------------------------- |
| `Cmd+T`          | Open the command bar to open a **new tab** (type a destination, Enter)        |
| `Cmd+L`          | Open the command bar aimed at the **current tab** (edit the address)          |
| `Cmd+N`          | New **window**                                                                |
| `Cmd+Shift+N`    | New **blank** tab (no command bar)                                            |
| `Cmd+W`          | Close the current tab (a split tab closes its focused pane)                    |
| `Cmd+Shift+T`    | **Reopen** the last closed tab or pane (repeat to walk back further)           |
| `Ctrl+Tab`       | Jump to the **most recently used** tab (a quick tap toggles back)             |
| `Ctrl+Shift+Tab` | Jump to the **least recently used** tab                                        |
| `Cmd+D`          | **Pin or unpin** the current tab (Arc-style favourites in place of bookmarks) |
| `Cmd+R`          | Reload the page                                                               |
| `Cmd+.`          | Stop loading                                                                  |
| `Cmd+[`          | Back                                                                          |
| `Cmd+]`          | Forward                                                                       |

Tab cycling follows **most-recently-used order**, not sidebar order: a quick
`Ctrl+Tab` toggles to the tab you were just on. Hold `Ctrl` to see the switcher —
a horizontal row of cards, most recent first, each with the page's thumbnail and
its favicon + web name; step with `Tab`/`Shift+Tab`, release `Ctrl` to commit,
and a bare `Ctrl` hold switches nothing. The switcher lists only tabs you've
**opened** this session (their page was actually shown) — restored-but-unopened
sidebar tabs stay out, so 30 tabs with 3 opened shows 3 cards, like Arc.
Switching tabs also gives the page keyboard focus, so the spacebar and arrow
keys work without a prior click into the page. Thumbnails are captured while a
tab is on screen, so opened tabs show their real content; a tab whose capture
isn't ready yet shows a favicon tile instead.

`Cmd+Shift+T` restores what was most recently closed,
in its original Space when it still exists: a closed tab comes back with its URL,
title, favicon, and pinned state; a closed **pane** of a split comes back in the
**same position** it left (Arc-style).

### Split view (panes)

| Shortcut             | Action                                                            |
| -------------------- | ----------------------------------------------------------------- |
| `Cmd+Shift+D`        | Open the command bar to **split** the current tab into a new pane |
| `Cmd+Shift+Option+D` | Close the focused pane                                            |

A tab holds up to **four panes**. Asking to split beyond four is declined rather
than replacing an existing pane.

Closing a split tab with `Cmd+W` (or the close button, or a swipe on a pane with
no back history) closes only the **focused pane** — the rest of the split stays.
Close the last remaining pane to close the tab itself. `Cmd+Shift+T` undoes a
pane close, re-inserting the pane at its previous position.

### Spaces

| Shortcut          | Action                               |
| ----------------- | ------------------------------------ |
| `Cmd+1` … `Cmd+9` | Switch to the Space in that position |

`Cmd+1…9` are always bound, even for positions that don't have a Space yet — an
index that doesn't exist is simply ignored, so the shortcuts don't shift around
as you add or remove Spaces. Create a Space from the **Spaces** menu → _New
Space_.

### Find, print, layout

| Shortcut      | Action                                                       |
| ------------- | ------------------------------------------------------------ |
| `Cmd+F`       | Show the find bar                                            |
| `Cmd+G`       | Find next                                                    |
| `Cmd+Shift+G` | Find previous                                                |
| `Cmd+P`       | Print the focused pane                                       |
| `Cmd+S`       | Toggle the sidebar                                           |
| `Cmd+Ctrl+S`  | Toggle **Presentation mode** (hide all chrome — for sharing) |
| `Cmd+Y`       | Open the **History** window                                  |
| `Cmd+,`       | Open **Settings** (General, Passwords, Privacy & Data, extensions) |

Find works whether or not the find field has focus, so you can find, click into
the page, and keep stepping through matches with `Cmd+G`.

## General settings

Open **Settings** with `Cmd+,` and pick **General** to choose:

- **Search engine** — Google, DuckDuckGo, Bing, Brave Search, or a **custom**
  provider (paste a query URL with `%s` where the query goes, e.g.
  `https://example.com/search?q=%s`). This is where the address bar and command
  bar send anything that isn't a URL.
- **New tab opens** — a **blank page**, the **search engine's home page**, or a
  **specific page** you choose. Applies to `Cmd+Shift+N`, the first tab on launch,
  and new split panes.
- **User agent** — how the browser identifies itself to sites. Pick **Default**
  (the browser's own), **Chrome**, **Firefox**, or **Safari — iPhone** (for a
  phone layout), or choose **Custom…** to type or paste any User-Agent string —
  the field is pre-filled with the current UA so you can start from a real string
  and tweak it. Handy for the occasional site that blocks non-Chrome browsers. It
  applies to every tab and
  takes effect on the next page load; leave a custom field empty to fall back to
  the default. Below the global setting, **per-domain rules** let one site (or a
  subdomain) send a different UA — e.g. keep a global Firefox UA but force
  `meet.google.com` back to Default. Rules match the most specific subdomain; a
  rule's **Default** disables the global choice for that domain only.
- **Archive inactive tabs** — how long an unpinned, non-folder tab may sit idle
  before it's auto-archived (Never / 1h / 6h / 12h / 24h). Tabs playing audio and
  tabs in a folder are never archived.
- **Gestures** — **swipe right to close**. The "undo page" swipe (two-finger
  rightward drag) closes a tab when it has no back history — or closes the Little
  Chord panel, if that's what you're swiping on. Off by default this is WebKit's
native behaviour (the swipe just does nothing); toggle it off here any time.
   When a page *does* have history, WebKit's own back-swipe is unchanged.

## Updates

**Settings → Updates** keeps Chord current without a manual download:

- The section shows the **installed version**, and a check against the GitHub
  releases page (`Drzaln/chord-browser`) runs automatically when you open it.
- If a newer release exists, a **Download & Install** button appears. Click it
  and Chord downloads the zip, extracts it, and replaces the copy in
  `/Applications`.
- Once installed, **Restart Now** quits Chord and relaunches the new version —
  your tabs, Spaces, and session are restored as on a normal quit.

Everything is manual: the check runs on open, but nothing downloads or installs
until you click. If the version you are running is newer than the latest release
(for example, a build ahead of the published one), the section simply says you're
up to date.

## Windows

`Cmd+N` opens a second window. Windows are independent in the ways you would
expect and shared in the ways you would want:

- **Per window:** the sidebar (collapsed or not, and its width), which Space is
  active, which tab is selected, the find bar, and the collapsed state of the
  Pinned section.
- **Shared:** your tabs, Spaces, folders, and everything on disk. Two windows are
  two views of one browser, not two profiles.

A tab can be **dragged from one window's sidebar into another's**. Within one
Space it just moves. Across Spaces you are asked to confirm first, because the
destination Space is a different cookie store — the page reloads there and may be
signed out. Dropping a tab into the other window's **content area** splits it, and
asks the same question when it crosses Spaces.

Menu commands act on the **focused** window: `Cmd+T`, `Cmd+L`, `Cmd+Y`, `Cmd+,`,
`Cmd+W`, `Cmd+D`, and `Cmd+Shift+D` all land where you are looking. A tab open in
*any* window is never auto-archived out from under it.

Which Space and tab each window had is **restored on relaunch**, and macOS brings
the windows themselves back through its own scene restoration — quit with two
windows and you get two back.

Two things stay on the first window rather than the focused one: **Little Chord**
panels and URLs opened from another app go where the store's focused window is
tracked, so if focus is ambiguous (no window key), they fall back to the first.

## Passwords

Chord has a built-in password vault. It offers to save a login when you sign in,
and fills it back on a click.

**Saving.** Sign in to a site and a bar appears at the top of the window: *Save
password?* with **Save**, **Not Now**, and **Never**. "Not Now" declines this one
time; **"Never" is remembered** and that site stops asking. Signing in again with
the *same* password says nothing at all — you are only asked when something is
new or changed, and a changed password offers **Update** rather than Save.

**Filling.** On a page with a saved login, a small **key** appears in the sidebar
next to the reload button. Click it to fill. With more than one account saved for
that site, the key opens a menu so you pick. Nothing is ever filled
automatically — no fill on page load, no fill when a field takes focus. A click
is always required.

**Where passwords live.** The username and site go in Chord's database; **the
password itself goes in the macOS Keychain**, never in the database. That means a
database backup, or anyone poking at the file, cannot contain your passwords.

**Managing them.** **Settings → Passwords** lists everything saved, with the site,
the account, and when it was last used. **Reveal** shows a password after Touch ID
(or your Mac's password); **the trash** deletes it, from the Keychain too. Sites
you told "Never" are listed at the bottom with an **Ask Again** button.

**What it will not do:**

- **Fill on a look-alike site.** A saved password is offered only on an *exact*
  origin match — same scheme, same host, same port. `evil.example.com` never sees
  a password saved for `example.com`.
- **Work over plain HTTP.** Saving and filling are HTTPS-only.
- **Fill inside an embedded frame**, which is the classic way credentials get
  stolen.
- **Sync anywhere.** Passwords stay on this Mac, like everything else in Chord.
- **Replace passkeys.** Chord cannot do passkeys at all — see
  [Capability summary](#capability-summary).

> **A dialog you may see:** after Chord is rebuilt from source, macOS may ask for
> your **login keychain password** the first time it reads a saved password. That
> is macOS noticing the app was rebuilt, not something being wrong. Click **Always
> Allow** and it stops for that build.

## Site permissions — camera, microphone, location, notifications

The first time a site asks for your **camera**, **microphone**, **location**, or
permission to send **notifications**, Chord asks you, once, and remembers the
answer. Camera and microphone are asked together when a site wants both.

Decisions are remembered per **site, per Space** — the same isolation your cookies
and logins already have. Allowing `meet.google.com` the camera in your Work Space
says nothing about the same site in another Space.

Review or undo them in **Settings → Privacy & Data → Site Permissions**: each row
shows the site, the Space, and what was allowed or blocked, with an **×** to
forget it. Forgetting means the site asks again next time.

Two permission layers are stacked, and **both** must say yes:

1. Chord's per-site decision, above.
2. macOS's own permission for the app, in **System Settings → Privacy & Security**
   (Camera, Microphone, Location, Notifications). The first time you allow a
   site, macOS asks for the app as a whole.

If a site you allowed still gets nothing, it is almost always layer 2 — check
System Settings. Chord cannot see or fix that state on your behalf.

**Notifications** work while Chord is running and the page is still open (the tab
may be in the background). They are **not** Web Push: a site you have closed
cannot wake the browser to notify you, because background push is gated to Safari
and unavailable to an app built on `WKWebView`. Clicking a banner focuses the tab
that posted it and runs the page's own click handler.

## Folders

Group tabs in the sidebar. Click the **folder+** button next to **New Tab** to
create one, then drop tabs in via a tab's right-click menu → **Move to Folder**.
A folder header toggles collapse on click; right-click it to rename or delete
(deleting keeps its tabs, now loose). Tabs inside a folder are **never
auto-archived**, so a folder is a safe place to keep things.

## Muting tabs

A tab making noise shows a speaker button in its sidebar row — click it to mute,
click again to unmute. Mute is also on the right-click menu, and it sticks across
reloads. Muting a split silences every pane.

## Screen sharing

When a site (Google Meet, Discord, etc.) asks to share your screen, macOS shows
its own picker with **Entire screen** and a **Window** list. Pick this browser's
window to share the page.

There is **no "Share this tab"** option — tab-level capture is a Chromium-only
feature, and Chord is built on WebKit, which does not offer it. Sharing the
window is the equivalent, and **Presentation mode** (`Cmd+Ctrl+S`, or the
**View** menu) makes it clean: it hides the sidebar and all browser chrome so the
shared window shows only the page. The traffic-light buttons stay so you can
always get out.

While a page is sharing your screen, a red **“This page is sharing your screen”**
banner appears at the top of the window running that page. Click **Stop** on it
to end sharing without digging through the site's own controls. (The banner marks
that the page is sharing *something* — WebKit doesn't say whether it's a screen,
this window, or another app's window — so it doesn't claim to know which.)

## Video quality

YouTube may serve you VP9 where Safari gets AV1, and Instagram/Facebook Reels can
look softer here than in Safari. That is not a setting you are missing and not the
User-Agent: macOS gives the **hardware AV1 decode path to Safari**, not to apps
built on `WKWebView`, so AV1 here would be software-decoded. Sites check whether a
codec decodes *power-efficiently*, see that AV1 does not, and pick their
next-best ladder. Everything else — VP9, HEVC, H.264 — is hardware-decoded
normally. There is no app-side fix; it may change in a future macOS.

## Peek

Click any link inside a **Favourite** or **Pinned** tab and instead of moving the
protected page away, the link opens in a small floating panel — already logged in
to whatever that Space is logged in to. It's a glance: press **⌘O** to promote it
into a real tab, or **Esc** to dismiss it. A link clicked in an ordinary
(ephemeral) tab still navigates that tab as usual. (This is distinct from Little
Chord, which opens an external link in a full floating window.)

## History

Press `Cmd+Y` to open the History window. History is **per-Space** — the window
shows only the pages you visited **in the active Space**, matching how cookies
and logins are already isolated per Space. The window's subtitle names the Space
it's showing.

It lists visits grouped by day, with a search box. Select rows and press
**Delete** (or use the right-click menu) to remove individual entries, open one
in a new tab, or copy its link. **Clear History…** at the bottom wipes the
**active Space's** history only; other Spaces are untouched. (To clear history
across _every_ Space at once, use **Settings → Privacy & Data**.)

The command bar (`Cmd+T` / `Cmd+L`) likewise ranks history from the active Space
only.

### Little Chord

| Shortcut | Action                                                                  |
| -------- | ----------------------------------------------------------------------- |
| `Cmd+O`  | **Promote** the Little Chord page into a full tab (while the panel is up) |
| `Esc`    | Dismiss the Little Chord panel                                            |

See [Little Chord](#little-arc-1) below.

### Debug (debug builds only)

| Shortcut     | Action                               |
| ------------ | ------------------------------------ |
| `Cmd+Ctrl+P` | Toggle the performance/debug overlay |

---

## The command bar

`Cmd+T` and `Cmd+L` both open the same fuzzy command bar; they differ only in
where the result lands (a new tab vs. the current tab). As you type it ranks:

- **Open tabs** and **history** by fuzzy match, and
- a raw **URL** or **search** fallback **pinned to the top** of the list, so
  Return always acts on exactly what you typed without scrolling for it.

`Cmd+L` opens the bar with the current tab's address already in the field and
selected, so the first keystroke replaces it — the same as the address button in
the toolbar. The bar takes keyboard focus whenever it opens (however you opened
it), so you can start typing immediately.

Press `Cmd+Enter` to send the result to a **new pane** (split) instead of a tab.

---

## Spaces

Spaces are isolated browsing contexts. Each Space has its **own cookie/website
data store**, so you can be signed into two different accounts for the same site
in two Spaces at once, and they won't see each other. Each Space carries its own
gradient theming in the sidebar.

- Switch with `Cmd+1…9` or by clicking the Space in the switcher.
- Switching back to a Space returns you to the tab you were last on.
- Create a Space from the **Spaces** menu.

Sessions persist per Space across quit-and-relaunch.

---

## Ephemeral tabs

Tabs opened for a quick look can be treated as **ephemeral**: a sweep timer clears
them automatically, with an archive so nothing is lost silently. This keeps the
tab list from accumulating one-off pages.

---

## Split view

Split a tab into side-by-side panes with `Cmd+Shift+D` — the command bar asks
what goes in the new pane, just like opening a new tab asks for a destination.
Close the focused pane with `Cmd+Shift+Option+D`. Up to four panes per tab.

---

## Little Chord

Little Chord is a floating panel for a **quick glance** at a page — read it, then
toss it, without adding a tab. There are two ways to open one:

1. **Right-click any link in a page → “Open in Little Chord.”** The link opens in
   the floating panel, using the active Space's session (so it's already logged
   in to whatever that Space is).
2. **Click a link in another app** (Mail, Messages, Notes…) while Chord is your
   default browser — it opens in Little Chord instead of stealing focus into the
   main window.

From the panel:

- Read the page in place, follow links, then
- press `Cmd+O` to **promote** it into a full tab in the active Space, or
- press `Esc` (or click away) to dismiss it — nothing is kept.

The panel is resizable, and its size is remembered: resize it once and the next
panel (Peek or Little Chord — they share it) opens at that size.

> **Testing it without setting a default browser:** from Terminal, run
> `open -a Chord https://example.com` — this routes a URL to Chord exactly like
> an external link and pops a Little Chord panel.

The Little Chord panel can be the only window open, so the app stays alive to
handle these even when the main window is closed.

Little Chord is distinct from Peek — see [Peek](#peek) above. The two share the
same floating panel; Peek is the inline preview of a favourite/pinned tab's
links, Little Chord is the external-link arrival.

---

## Downloads

Downloads are handled natively via `WKDownload`, with a progress UI. Files land
in your Downloads folder.

> Per the app's safety posture, be deliberate about downloading and running files
> from untrusted sources.

---

## Session restore

State is persisted continuously (`interactionState` per pane). After a force-quit
or crash, relaunching restores your Spaces, tabs, panes, and per-page scroll/form
state — process-termination recovery is built in.

---

## Content blocking

Content blocking is **on by default**. It compiles EasyList + EasyPrivacy into
native `WKContentRuleList`s, caches them on disk, and refreshes weekly. It does
two things:

- **Network filtering** — drops ad/tracker requests before they hit the network.
- **Cosmetic filtering** — hides ad elements on the page (`css-display-none`),
  including standard CSS `:has()` container-hiding rules (hide the wrapper that
  _contains_ an ad).

**What the network/cosmetic blocker can't touch:** YouTube (and other
first-party-served) **video ads**. Those are served from the same domain and
player as the video itself, so there's no request to drop and nothing to hide by
URL. That's a real limit of `WKContentRuleList` — see the
[README](../README.md#content-blocking) and
[BROWSER_SPEC §4.8](../BROWSER_SPEC.md).

## YouTube ad blocking

YouTube and **YouTube Music** ads *are* blocked, by a dedicated built-in that
does not go through the content blocker above (it can't — see the note there).
Instead a small script runs on YouTube pages and:

- **Skips video ads** — clicks _Skip_ the moment it appears, and runs any
  remaining ad at high speed so even "unskippable" ads end in a fraction of a
  second.
- **Hides static ads** — mastheads, promoted rows, in-feed ad slots, and YouTube
  Music's ad slots.

It's **on by default** and needs no extension. Honest caveat: YouTube actively
fights ad blockers and changes its page constantly, so this is best-effort — it
may occasionally miss a new ad format until the selectors are updated, and it is
not the same as running full uBlock Origin. While an ad is playing it is also
**muted** (so the fast-forward never blasts its audio), but your own per-tab
mute choice is restored the moment the ad ends — the ad blocker only hides the
ad's sound, it never overrides yours. Why a bespoke script instead of an
extension is explained just below.

### "But Arc / Brave / Orion block YouTube ads with the same extension!"

True — and the reason is the **browser engine**, never the extension:

- **Arc, Brave, Edge, Chrome** are **Chromium** browsers. They run the full Chrome
  extension engine — high rule limits, request-blocking `webRequest`, and
  scriptlet injection — so AdBlock/uBlock Origin block YouTube ads there.
- **Orion** is WebKit like this browser, but Kagi **rebuilt the extension runtime
  themselves** to add those same capabilities. That custom engine — not WebKit
  itself — is what lets it run real uBlock Origin.
- **This browser** is WebKit + Apple's `WKWebExtension`, which caps blocking rules
  (~50k) and offers no request-blocking or scriptlet injection. So a Chrome ad
  blocker's rules are rejected and YouTube ads can't be touched. It's inherent to
  the native-WebKit, low-memory design — not a bug, and not fixable with a
  setting.

**Bottom line:** for everyday blocking, rely on the **built-in content blocker**
above (it's fed the same EasyList/EasyPrivacy data an ad blocker uses), plus the
**built-in YouTube ad skipper**. Installing AdBlock or uBlock Origin Lite won't
add anything for YouTube, and classic uBlock Origin won't even enable (it's
Manifest V2; this browser is MV3-only) — which is exactly why YouTube blocking is
built in as its own script rather than left to an extension.

There is currently **no in-app toggle** to disable blocking or whitelist a
specific site; both are noted as possible future additions.

---

## Settings

Open Settings with `Cmd+,` (or the app menu → _Settings…_). It's a sheet with
four sections: **General** (search engine, new-tab behaviour, User-Agent, archive
timing — described [above](#general-settings)), **Passwords** (see
[Passwords](#passwords)), **Privacy & Data**, and **Extensions**.

### Privacy & Data — clear browsing data

Tick what you want to remove and click **Clear Data** (you'll be asked to
confirm — it can't be undone):

- **Cached files and images** — frees disk space, doesn't sign you out.
- **Cookies and other site data** — signs you out of sites, **in every Space**.
- **Local & session storage** — localStorage, IndexedDB, service workers.
- **Browsing history** — the list of pages you've visited.

Website data (cache/cookies/storage) is cleared across **every Space** at once;
history is cleared from the app's own database. Each Space's store is cleared
independently, so isolation is preserved.

Below the clear-data controls, **Site Permissions** lists every camera,
microphone, location, and notification choice you have made, per Space, with an
**×** to forget one — see
[Site permissions](#site-permissions--camera-microphone-location-notifications).

### Extensions

See below.

---

## Extensions

The browser hosts WebKit web extensions (`WKWebExtension`). Extensions run
**per Space** — each Space that enables an extension gets its own background
worker process, which is why the management panel shows you how many are running.

### Installing and managing extensions

Open **Settings** (`Cmd+,`) → **Extensions**:

1. Click **Add Extension…** and pick a **Chrome `.crx`** or **Firefox `.xpi`**
   file. It's unpacked and normalised into an on-disk library.
2. Each installed extension shows a row with an **Enabled** switch — turning it on
   loads the extension into the **active Space** (extensions are per-Space, so
   enable it in each Space where you want it).
3. **Grant host access when prompted.** On enable, a sheet lists the sites the
   extension wants to read and change (e.g. all sites for an ad blocker, just
   `youtube.com` for a YouTube tweaker). Click **Allow** — **without this the
   extension is loaded but inert**, because WebKit does not auto-grant host
   access. After you allow, open tabs reload so the extension takes effect.
4. The **trash** button uninstalls an extension: it's unloaded from every Space
   and deleted from the library.

> **Ad blockers (AdBlock, uBlock Origin) don't really work here — by design.** A
> Chrome ad blocker blocks via `declarativeNetRequest`, and its rule set (AdBlock
> ships ~63k rules) is far larger than WebKit's ~50k limit, so the rules are
> rejected and it blocks nothing. Classic **uBlock Origin won't even enable**
> (it's Manifest V2; this browser is MV3-only), and uBlock Origin **Lite** hits
> the same rule wall. This is the WebKit + Apple-extension-API limit, not a bug —
> see ["But Arc / Brave / Orion block YouTube ads…"](#but-arc--brave--orion-block-youtube-ads-with-the-same-extension)
> under Content blocking. **Use the built-in content blocker instead** (on by
> default, fed the same filter lists). No extension can block YouTube video ads
> here.

Once enabled, an extension also appears in the sidebar and behaves like this:

- **Toolbar action buttons** — each enabled extension in the active Space shows a
  button in the sidebar header; clicking it fires the extension's action or shows
  its popup.
- **Manage panel** — the `…` (ellipsis) button in the sidebar opens a per-Space
  panel listing loaded extensions, whether each runs a background worker, and an
  **"Access on all sites"** toggle for host permissions.
- **Permission prompts** — when an extension requests access, a grant/deny sheet
  appears; grants are remembered across launches.
- **Restore on launch** — extensions you had enabled are re-loaded into their
  Spaces after session restore.

---

## Capability summary

| Capability                                                | Status                                  |
| --------------------------------------------------------- | --------------------------------------- |
| Tabbed browsing, favicons, titles                         | ✅                                      |
| Multiple windows (`Cmd+N`), cross-window tab drag         | ✅ (Space/tab per window restored)      |
| Camera & microphone, asked once per site and Space        | ✅                                      |
| Web geolocation (`navigator.geolocation`), asked once per site and Space | ✅ (host `CLLocationManager` shim)   |
| Saving and filling passwords, with a Keychain-backed vault | ✅                                     |
| Passkeys                                                  | ❌ not available to a WKWebView app     |
| Password-manager extensions (Bitwarden, 1Password)        | ❌ MV3 APIs missing; use the built-in vault |
| Web notifications while the page is open                  | ✅ (per-site, per-Space)                |
| Background Web Push (site closed)                         | ❌ Safari-gated, not available to WKWebView |
| YouTube / YouTube Music ad skipping (built-in script)     | ✅ best-effort                          |
| Hardware AV1 decode                                       | ❌ software-only outside Safari         |
| Command bar (fuzzy tabs + history + URL/search)           | ✅                                      |
| Spaces with isolated cookie stores                        | ✅                                      |
| Ephemeral tabs with auto-sweep + archive                  | ✅                                      |
| Split view (up to 4 panes)                                | ✅                                      |
| Little Chord (external-link panel)                          | ✅                                      |
| Session restore after force-quit                          | ✅                                      |
| Downloads with progress                                   | ✅                                      |
| Find-in-page, print, PDF viewing                          | ✅                                      |
| Native content blocking (network + cosmetic, `:has()`)    | ✅ (on by default)                      |
| Extension hosting (buttons, panel, permissions, restore)  | ✅                                      |
| In-app extension install / enable / uninstall (Settings)  | ✅                                      |
| Settings: clear cache / cookies / storage / history       | ✅                                      |
| Per-site blocking whitelist / disable toggle              | ⚠️ not implemented                      |
| Chrome ad blockers (AdBlock / uBlock Origin) blocking ads | ❌ WebKit rule limits + no scriptlets   |
| YouTube / first-party video-ad blocking                   | ❌ not possible via `WKContentRuleList` |

Default search engine is **Google**. Deployment target is **macOS 15.4+**.
