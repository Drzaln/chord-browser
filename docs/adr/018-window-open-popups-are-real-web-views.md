# 018 — `window.open()` popups are real web views hosted as tabs

**Status:** accepted (post-M7, shipped 2026-08-08)

## Context

`window.open()` (and `target="_blank"`) requests arrived at
`createWebViewWith`, which returned `nil` and asked the store to open a
**plain** tab at the requested URL. That tab was a brand-new `WKWebView` with no
relationship to the page that asked.

That broke every OAuth popup flow, most visibly **Shopee Indonesia's
"Continue with Google"**: the Google tab opened, the user logged in, Google
redirected the popup back to Shopee's callback — and nothing happened. Shopee
stayed on the login page and the Google tab lingered forever. Two concrete
causes:

- **`window.close()` is ignored on a normal tab.** Browsers only let a
  script-created window close itself; a store-opened tab is not one, so the
  popup could never tidy itself up.
- **The page's `window.open()` call got no usable reference.** A plain tab is
  created out-of-band, so `window.open()` had nothing to poll (`win.closed`) or
  read the auth result from.

## Decision

**Return a real `WKWebView` from `createWebViewWith`, and host *that* view as
the tab.**

- The engine builds the popup from the opener's `WKWebViewConfiguration`, so it
  shares the opener's data store (the same cookies — essential for a Google →
  Shopee callback), extension controller, and preference set, and WebKit
  performs the navigation into the returned view itself.
- The view is registered in the web-view pool under a fresh pane id **before**
  the store is told to open the tab, so when the tab is selected the
  `surface(for:in:)` path finds and shows that exact view instead of building a
  fresh normal one. The store creates the tab's pane with that same id
  (`newTab(paneID:url:in:)`).
- `window.close()` now reaches `WKUIDelegate.webViewDidClose`, which closes the
  popup's tab (`panePopupDidClose`). A "Continue with Google" popup no longer
  lingers.
- The page keeps the live `window.open()` reference, which is what OAuth flows
  actually poll. **`window.opener` stays `null`** — WKWebView does not expose
  it — but the `window.open()` return value is the mechanism these flows use to
  hand the result back, and the e2e test asserts exactly that.

The two new-window shapes are unified: a plain `target="_blank"` anchor
(`.linkActivated`) and a JS `window.open` (`.other`) both become popup views.
The user-visible outcome is unchanged — a new tab — so there is no downside to
applying popup semantics to both, and it means OAuth works regardless of which
mechanism a site uses. The Peek gate (a link clicked inside a favourite/pinned
tab) still runs first and returns `nil` to lift the click into the panel.

## Consequences

- **The popup keeps its cookies and session.** Because it is built from the
  opener's configuration, a private-window popup stays in the private session,
  and a Space's popup sees that Space's data store — the tab is placed in the
  window showing the page that asked (`window(showingPane:)`), which is also
  where the private/Space data store comes from.
- **User-close still works.** Closing the popup tab evicts its view like any
  other tab; `window.close()` is simply an additional way to close it.
- **Eviction edge case.** If the popup's view is LRU-evicted mid-flow (unlikely —
  OAuth popups are short-lived and the pool caps at 12), its tab reverts to a
  normal view on revive; by then the popup's job is done.
- **The UA is resolved at creation** (`applyUserAgent(to:for:)`), the same as a
  normal pane's first view, so the popup's *first* navigation is not
  cancelled-and-re-issued by the policy — re-issuing that first load is what
  detaches the window reference.
- **`paneRequestedNewTab` was removed.** The old "open a URL in a new tab"
  engine callback had exactly one caller, `createWebViewWith`, which now sends
  `paneRequestedPopup` instead; the protocol, `TabStore`, and the test fake were
  cleaned of it.
- Verified by `PopupE2ETests` (real engine + real HTTP): `window.open()` returns
  a live reference, the popup loads its destination, `window.close()` closes its
  tab, and the opener observes `win.closed === true`.
