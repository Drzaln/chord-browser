# 025 — Chrome identities, prepared bundles, and a narrow shim

**Status:** accepted (M8 foundation, 2026-10-26) — extends ADR 011

M7 loaded an opaque ZIP and gave each extension a filename slug as its WebKit
identity. That was enough for a local preview, but not for anything Chrome
expects: native-messaging hosts list `chrome-extension://<id>/` origins, extension
storage is filed under that origin, and a future store/update path needs the same
id across renames and re-launches.

## Chrome ids

Every installed bundle now carries a Chrome-style id: 32 letters from `a` to `p`.
A CRX3 bundle's `signed_header_data.crx_id` is authoritative, and the RSA proof
key must hash to it; CRX2 derives the id from its embedded public key; a plain
ZIP/XPI uses its manifest `key`, then its source path. `WebKitExtensionHost` sets
`context.uniqueIdentifier` to that id and `context.baseURL` to
`chrome-extension://<id>/`, and registers the `chrome-extension` scheme once.
The per-Space controller still owns storage and workers, so the same id in two
Spaces remains isolated.

## Raw ZIP plus prepared directory

The signed ZIP is kept at `<slug>.zip`. A prepared copy at `<slug>.prepared` is
what WebKit loads. Preparation is the only place Chord edits an extension's
files: the shim is injected into the worker, content scripts and HTML pages.

The order matters: verify the signature first, then unpack with `/usr/bin/ditto`,
reject symlinks, prepare, and atomically swap the prepared tree into place. A
bundle that cannot unpack still installs as a raw ZIP and fails at load, rather
than disappearing from the library. Old ZIP-only installs are prepared on the
next enable (`ExtensionInstaller.prepareIfNeeded`).

This supersedes ADR 011's "store a ZIP, not an unpacked directory" for bundles
that can be prepared. The ZIP remains the provenance copy; the directory is a
derived cache, not a new source of truth.

## Narrow shim, not a WebExtensions rewrite

`WKWebExtension` remains the runtime. The shim exists only for APIs WebKit does
not implement, and starts with `chrome.offscreen`. It is injected as a file and
talks to the app through the reserved native-messaging endpoint `chord`; real
native hosts still require the extension's own `nativeMessaging` permission,
recorded separately in `.chord-added`.

This does not reopen BROWSER_SPEC §4.7's warning about Orion: the shim is not a
general API implementation, and every API added must have a narrow native
answer, a permission gate, and a test. Chrome Web Store install/update remains
out of scope.

## Worker health

Extension restoration is sequential with a short gap after a background worker;
stale service-worker registrations are cleared once per Space when the shim
version changes; and a context whose background worker reports a start failure
is unloaded/reloaded once a minute. Clearing registrations also clears website
service workers in that Space; they register again on their next visit.

## Consequences

- Native messaging, extension origins and future store updates now agree on one
  id.
- The prepared directory is disposable: deleting it re-prepares from the ZIP.
- The shim is a compatibility surface with a real maintenance cost; additions
  need real-extension tests, not just unit tests.
- Offscreen message routing, the rest of the Chrome API surface, and the store
  flow remain future work.
