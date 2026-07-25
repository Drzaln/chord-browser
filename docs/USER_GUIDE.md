# User Guide

How to drive the browser day-to-day: keyboard shortcuts, the command bar, Spaces,
split view, Little Arc, downloads, find-in-page, content blocking, and extensions.

This guide describes what is actually wired in the shipping app. Where a
capability exists in the engine but has no user-facing control yet, it says so
plainly.

---

## The basics

The browser is a **single window**. The sidebar on the left holds the Space
switcher, the tab list, navigation controls, and any extension action buttons.
Web content sits in an inset card to the right.

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

There is currently **no in-app toggle** to disable blocking or whitelist a
specific site; both are noted as possible future additions.

---

## Extensions

The browser hosts WebKit web extensions (`WKWebExtension`). Extensions run
**per Space** — each Space that enables an extension gets its own background
worker process, which is why the management panel shows you how many are running.

What's wired in the UI today:

- **Toolbar action buttons** — each enabled extension in the active Space shows a
  button in the sidebar header; clicking it fires the extension's action or shows
  its popup.
- **Manage panel** — the `…` (ellipsis) button opens a per-Space panel listing
  loaded extensions, whether each runs a background worker, and an **"Access on
  all sites"** toggle for host permissions.
- **Permission prompts** — when an extension requests access, a grant/deny sheet
  appears; grants are remembered across launches.
- **Restore on launch** — extensions you had enabled are re-loaded into their
  Spaces after session restore.

### Installing an extension — current limitation

The engine can install and normalise both **Chrome `.crx`** and **Firefox
`.xpi`** bundles into an on-disk library and enable them per Space
(`ExtensionsService.install(from:)` → `enable(slug:in:)`). **However, there is no
user-facing "Add Extension" button or file picker wired into the shipping UI
yet.** In practice that means:

- Extensions already installed and enabled will **restore and appear** on launch
  (buttons + manage panel + host-access controls all work), but
- there is currently no in-app way to pick a new `.crx`/`.xpi` from disk and
  install it. That control is a known gap, not a hidden menu.

If you're building/running from source and want to load one, drive the
`ExtensionsService` API directly (see
`Packages/Sources/BrowserStore/ExtensionsService.swift`).

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
| In-app extension install / file picker | ⚠️ not wired yet |
| Per-site blocking whitelist / disable toggle | ⚠️ not implemented |
| YouTube / first-party video-ad blocking | ❌ not possible via `WKContentRuleList` |

Default search engine is **Google**. Deployment target is **macOS 15.4+**.
