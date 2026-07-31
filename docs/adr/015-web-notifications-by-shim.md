# 015 — Web notifications by an in-page shim, and no Web Push

**Status:** accepted (post-M7, 2026-07-27, permission model amended by ADR 014)

## Context

Sites the browser is used with daily (Slack, chat apps, calendars) call
`Notification.requestPermission()` and `new Notification(...)`. Public `WKWebView`
implements neither: there is no notification permission callback, no display hook,
and no delegate for a click — verified against `WKUIDelegate.h`. Safari has this
because WebKit's notification support is wired to Safari, not exposed on the
embeddable view.

Without something, `window.Notification` is simply undefined, and the affected
sites either nag on every visit or degrade in ways that look like the browser is
broken.

## Decision

`NotificationBridge` replaces `window.Notification` with a shim, injected
`atDocumentStart` into **all** frames (embedded widgets post notifications too).
It reports permission, forwards each `new Notification(...)` to the native side
over a message handler, and exposes `window.__chordNotifyClick(id)` so a click on
the delivered banner fires that page instance's `onclick`.

Two message handlers, deliberately different shapes:

- `chordNotifyShow` — plain handler, one-way; there is nothing to return.
- `chordNotifyPermission` — a **with-reply** handler, because the page is awaiting
  a decision. It carries an `op`: `query` reads the remembered per-origin decision
  without prompting (this is what seeds `Notification.permission` at load), and
  `request` is `requestPermission()` and may prompt (ADR 014).

Delivery is `UNUserNotificationCenter` from the app layer (`NotificationController`),
and a click routes back through `TabStore.handleNotificationClick` to focus the
tab and run the page's handler.

## Consequences

- **This is not Web Push.** Notifications work while the app is running and the
  page is open — the tab may be backgrounded or occluded, but a closed site
  delivers nothing. Background delivery needs APNs / declarative web push, which
  is Safari-gated and unavailable to a WKWebView app. Say so plainly rather than
  implying parity.
- The shim is observable to pages: `Notification` is not the native class, and a
  site that feature-detects hard enough can tell. Nothing encountered so far does.
- Like `MediaActivityMonitor` (ADR 008) and `ScreenShareMonitor` (ADR 012), the
  handlers are per-view leak sources (§6.7): they are installed on the **per-view**
  `WKUserContentController`, never the shared configuration template — `copy()`
  shares that controller and a duplicate handler name takes the app down on the
  second tab — and removed in `LiveWebView.tearDown()`.
- Two permission layers stack: the per-site decision (ADR 014) and macOS's
  app-level authorization, which is the delivery backstop. Both must be granted,
  and a failure in the OS layer looks, from the page's side, like a granted
  notification that never appears.
