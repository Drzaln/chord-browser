# 014 — Camera, microphone, and notifications are asked once, per Space and origin

**Status:** accepted (post-M7, 2026-07-29 / 2026-07-31)

## Context

Media capture arrived with multi-window's feature batch as a blanket grant:
`NavigationCoordinator` implemented
`requestMediaCapturePermissionForOrigin…` and returned `.grant` unconditionally,
because that was the smallest thing that made Google Meet's camera reach the OS
TCC prompt. It also meant *every* page could open the camera and microphone
without ever asking — the browser had no per-site decision at all, only macOS's
one-time, app-wide TCC grant underneath it.

Web notifications had the mirror-image problem. Public `WKWebView` exposes no
notification hook (verified against `WKUIDelegate.h`), so `window.Notification`
is shimmed in-page (ADR 015). The first cut seeded the shim's `permission` from
the **OS** authorization state, which is app-wide: one grant meant every site was
permitted, and a site that had never been asked read someone else's answer.

Three levels of state were in play and only two were being used: macOS's TCC
grant for the *app*, WebKit's own per-origin state (which the public API does not
let us drive for these), and the browser's own record — which did not exist.

## Decision

There is one model for all three capabilities: a decision is remembered per
**(Space, origin, kind)**, asked once, and reused thereafter.

- `SitePermissionKind` (`camera`, `microphone`, `notification`) and
  `SitePermissionDecision` (`granted`, `denied`) live in `BrowserCore` — WebKit-free,
  so `BrowserStore` can hold the policy and `BrowserPersistence` can store it.
- A request that has no remembered decision is **suspended** behind a
  `SitePermissionPrompt` → `SitePermissionSheet`, and resolved by
  `TabStore.requestSitePermission` / `resolveSitePermission`. Camera and
  microphone arrive together when a site asks for both, and are answered together,
  matching how browsers present them.
- The notification shim **queries** the remembered decision at document start (no
  prompt — this is what seeds `Notification.permission` and stops a returning
  Slack tab from re-asking on every visit) and **prompts** only on
  `Notification.requestPermission()`.
- Storage is SQLite: migration `v10_site_permissions` adds the table,
  `v11_site_permissions_per_space` re-scopes it to a Space, adopting existing rows
  into the first Space rather than dropping them (the same non-destructive shape
  as `v6_history_per_space`; §7.2 forbids deleting user data in a migration).
- **Settings → Privacy & Data** lists the remembered choices per Space and lets
  one be revoked, so an answer given once is not permanent.

Scoping to a Space rather than globally is the point that took the decision:
cookies, site storage, and extension grants are all already per-Space (ADR 006,
ADR 011). A camera decision that leaked across Spaces would be the one identity
boundary that did not hold, in the one place where the cost of getting it wrong is
a live microphone.

## Consequences

- A granted notification also asks macOS for authorization, since the OS grant is
  the delivery backstop — the site-level answer cannot conjure a banner on its own.
- Two permission systems remain stacked, and both must be green: ours per site,
  macOS's per app. A user who denies the app in System Settings sees a granted
  site do nothing, and neither layer can report the other's state.
- **The microphone needs two entitlement keys, not one.** Hardened Runtime (on in
  Release) gates the mic behind `com.apple.security.device.audio-input`, which is
  a *different* key from App Sandbox's `com.apple.security.device.microphone`.
  Camera shares one key across both, so the camera worked in Release while the mic
  did not — and Debug hid it entirely, because ad-hoc signing disables Hardened
  Runtime and only the sandbox key is consulted there. Both keys are declared. A
  bug of this shape cannot be caught by `swift test` (unsandboxed) or by a Debug
  build; only a production build shows it.
- **Screen sharing is not part of this.** `WKMediaCaptureType` covers camera and
  microphone only, and public `WKWebView` exposes no display-capture hook, so
  `getDisplayMedia` never reaches this path — it goes straight to the OS picker.
  What the app does around that is ADR 012.
