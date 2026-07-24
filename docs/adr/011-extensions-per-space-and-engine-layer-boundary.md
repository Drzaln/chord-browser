# 011 — Extensions are per-Space; the engine *layer* is the WebKit boundary

**Status:** accepted (M7) — resolves BROWSER_SPEC 12's open decision, amends 7.1

Two decisions M7 forces, taken together because the second follows from the
first.

## Per-Space extension contexts

The §12 open decision — extension contexts per-Space or global — is resolved
**per-Space**. Each Space loads its own copy of an enabled extension, with
isolated storage, permissions, and (once contexts load, 7.3+) background
workers.

This is the same isolation Spaces already give cookies and localStorage
(§3.3, ADR 006), extended to extensions, and WebKit supports it directly:
`WKWebExtensionController.Configuration(identifier:)` gives persistent,
per-identifier on-disk storage — the exact analogue of
`WKWebsiteDataStore(forIdentifier:)`. So there is **one
`WKWebExtensionController` per Space**, its configuration keyed by the Space's
`dataStoreID` and its `defaultWebsiteDataStore` set to that same identifier, so
extension data lands beside the cookies it belongs with.

The cost is real and accepted: a background service worker is one process *per
Space it is enabled in*, not one globally. §6.6 already asks that per-extension
memory be surfaced in the UI; per-Space makes that surfacing matter more, and a
later phase does it. A global controller would have been cheaper but would have
punched a hole straight through the isolation that is the reason Spaces exist —
one extension seeing every Space's storage and every Space's tabs.

Rejected alternative: a single shared controller with per-Space *contexts*.
`WKWebExtensionContext` does not partition website data on its own; the storage
isolation lives on the controller's configuration and data store. Sharing the
controller would share the store.

## The engine *layer* is the WebKit boundary

§7.1 said `BrowserEngine` is the only package that imports WebKit. The extension
host also needs WebKit — it constructs `WKWebExtensionController`s — and folding
it into `BrowserEngine` would make that package own two unrelated jobs (page
rendering and extension hosting), against §7.6's "no file/target doing two
jobs."

So there is a second WebKit importer, `BrowserExtensions`, and §7.1 is amended
from "`BrowserEngine` is the only WebKit importer" to **"the engine *layer* is
the WebKit boundary."** Both packages import WebKit; neither lets a `WK*` type
cross into Store or UI. The rule that actually protects view code is unchanged:
no framework type appears in any signature `BrowserUI` or `BrowserCore` can see.

The seam is the same opaque-wrapper trick as `AnyWebSurface`:

- `BrowserEngine` declares `ExtensionControllerHandle` — an opaque struct whose
  `WKWebExtensionController` is *internal* to the engine — and a WebKit-free
  `ExtensionControllerProviding` protocol (`Space` in, opaque handle out).
- `BrowserExtensions` owns `ExtensionHost` (WebKit-free) and the concrete
  `WebKitExtensionHost`, which builds the controllers and conforms to
  `ExtensionControllerProviding`.
- The engine attaches `config.webExtensionController = handle.controller` when
  it builds a Space's web view, unwrapping the handle on its own side of the
  seam.

Because the provider and the host are both WebKit-free in their public surface,
`AppEnvironment` — in the WebKit-free `BrowserStore` — wires the host to the
engine without ever naming a `WK*` type. `BrowserStore` gains a dependency on
`BrowserExtensions`; dependencies still flow downward (Store sits above both
Engine and Extensions).

## Flagged off while it is built

M7 spans several commits (7.1–7.6). Per §7.4 the whole subsystem sits behind
`FeatureFlags.extensionsEnabled`, **default off**. With it off,
`AppEnvironment` builds no host and sets no provider, so the engine attaches no
controller and the shipping browser is byte-for-byte what it was before M7. The
flag is deleted when the milestone ships.

## What 7.1 does *not* do

7.1 is the seam, the package, and per-Space controller *wiring* only. No `.crx`
is unpacked, no `WKWebExtensionContext` is loaded, no tab/window model is
implemented. Those are 7.2–7.5. The host at 7.1 can stand up a per-Space
controller and hand it to the engine; that is the whole claim, and it is what
the tests cover.
