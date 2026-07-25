# Chord Browser — User Guide

How to drive Chord Browser day-to-day: keyboard shortcuts, the command bar, Spaces,
split view, Little Arc, downloads, find-in-page, content blocking, and extensions.

This guide describes what is actually wired in the shipping app. Where a
capability exists in the engine but has no user-facing control yet, it says so
plainly.

---

## The basics

Chord is a **single window**. The sidebar on the left holds the Space switcher,
the tab list, navigation controls, and any extension action buttons. Web content
sits in an inset card to the right. The sidebar and the frame around the card are
**frosted glass** — translucent `.ultraThinMaterial` tinted by the active Space's
color, blurring your desktop behind the window (the web page itself stays opaque).

- **Address / search:** press `Cmd+L` (or `Cmd+T`) to open the command bar, type
  a URL or a search query, and press Enter. Anything that isn't a recognisable
  URL is sent to **Google** as a search.
- **Back / forward:** `Cmd+[` and `Cmd+]`, or the chevrons in the sidebar.
- **Reload:** `Cmd+R`. While a page is loading the reload button becomes a stop
  button.

---

## Keyboard shortcuts

### Tabs & navigation

| Shortcut | Action |
| --- | --- |
| `Cmd+T` | Open the command bar to open a **new tab** (type a destination, Enter) |
| `Cmd+L` | Open the command bar aimed at the **current tab** (edit the address) |
| `Cmd+N` | New **blank** tab (no command bar) |
| `Cmd+W` | Close the current tab |
| `Cmd+R` | Reload the page |
| `Cmd+[` | Back |
| `Cmd+]` | Forward |

### Split view (panes)

| Shortcut | Action |
| --- | --- |
| `Cmd+Shift+D` | Open the command bar to **split** the current tab into a new pane |
| `Cmd+Shift+Option+D` | Close the focused pane |

A tab holds up to **four panes**. Asking to split beyond four is declined rather
than replacing an existing pane.

### Spaces

| Shortcut | Action |
| --- | --- |
| `Cmd+1` … `Cmd+9` | Switch to the Space in that position |

`Cmd+1…9` are always bound, even for positions that don't have a Space yet — an
index that doesn't exist is simply ignored, so the shortcuts don't shift around
as you add or remove Spaces. Create a Space from the **Spaces** menu → *New
Space*.

### Find, print, layout

| Shortcut | Action |
| --- | --- |
| `Cmd+F` | Show the find bar |
| `Cmd+G` | Find next |
| `Cmd+Shift+G` | Find previous |
| `Cmd+P` | Print the focused pane |
| `Cmd+S` | Toggle the sidebar |
| `Cmd+,` | Open **Settings** (clear browsing data + extensions) |

Find works whether or not the find field has focus, so you can find, click into
the page, and keep stepping through matches with `Cmd+G`.

### Little Arc

| Shortcut | Action |
| --- | --- |
| `Cmd+O` | **Promote** the Little Arc page into a full tab (while the panel is up) |

See [Little Arc](#little-arc) below.

### Debug (debug builds only)

| Shortcut | Action |
| --- | --- |
| `Cmd+Ctrl+P` | Toggle the performance/debug overlay |

---

## The command bar

`Cmd+T` and `Cmd+L` both open the same fuzzy command bar; they differ only in
where the result lands (a new tab vs. the current tab). As you type it ranks:

- **Open tabs** and **history** by fuzzy match, and
- a raw **URL** or **search** fallback that always stays reachable at the bottom,
  so you can always just navigate to exactly what you typed.

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

## Little Arc

When you click a link in **another app**, it opens in a floating **Little Arc**
panel rather than stealing focus into the main window. From the panel:

- Read the page in place, or
- press `Cmd+O` to **promote** it into a full tab in the browser.

The Little Arc panel can be the only window open, so the app stays alive to
handle these even when the main window is closed.

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
  *contains* an ad).

**What it can't block:** YouTube (and other first-party-served) **video ads**.
Those are served from the same domain and player as the video itself, so there's
no request to drop and nothing to hide. Blocking them requires runtime JavaScript
injection (scriptlets) — how Brave and uBlock Origin do it — which Apple's
`WKContentRuleList` API does not allow. That's an architectural limit, not a
setting you can flip. See the [README](../README.md#content-blocking) and
[BROWSER_SPEC §4.8](../BROWSER_SPEC.md) for the full explanation.

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
above (it's fed the same EasyList/EasyPrivacy data an ad blocker uses). Installing
AdBlock or uBlock Origin Lite won't add YouTube blocking, and classic uBlock
Origin won't even enable (it's Manifest V2; this browser is MV3-only).

There is currently **no in-app toggle** to disable blocking or whitelist a
specific site; both are noted as possible future additions.

---

## Settings

Open Settings with `Cmd+,` (or the app menu → *Settings…*). It's a sheet with two
sections:

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

| Capability | Status |
| --- | --- |
| Tabbed browsing, favicons, titles | ✅ |
| Command bar (fuzzy tabs + history + URL/search) | ✅ |
| Spaces with isolated cookie stores | ✅ |
| Ephemeral tabs with auto-sweep + archive | ✅ |
| Split view (up to 4 panes) | ✅ |
| Little Arc (external-link panel) | ✅ |
| Session restore after force-quit | ✅ |
| Downloads with progress | ✅ |
| Find-in-page, print, PDF viewing | ✅ |
| Native content blocking (network + cosmetic, `:has()`) | ✅ (on by default) |
| Extension hosting (buttons, panel, permissions, restore) | ✅ |
| In-app extension install / enable / uninstall (Settings) | ✅ |
| Settings: clear cache / cookies / storage / history | ✅ |
| Per-site blocking whitelist / disable toggle | ⚠️ not implemented |
| Chrome ad blockers (AdBlock / uBlock Origin) blocking ads | ❌ WebKit rule limits + no scriptlets |
| YouTube / first-party video-ad blocking | ❌ not possible via `WKContentRuleList` |

Default search engine is **Google**. Deployment target is **macOS 15.4+**.
