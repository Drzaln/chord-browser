# 026 — Chrome Web Store install through the public CRX endpoint

**Status:** accepted (M9c, 2026-10-26) — supersedes BROWSER_SPEC §4.7's blanket
"do not attempt Chrome Web Store install flows"

## Context

Search installs Chrome extensions directly: a store link or 32-letter id is
resolved to the same public `clients2.google.com/service/update2/crx` address
every Chromium browser uses, the CRX3 signature is checked, and the ZIP is
installed. Search also relays the store page's disabled "Add to Chrome" button
into "Add to Search".

Chord already has the signature verifier, the prepared-bundle installer and a
per-Space extension host. Refusing store installs leaves the most common way
people find extensions broken.

## Decision

Support **install by store link or id** in Settings:

- read the id only from a validated https store path, or a bare 32-letter id;
- fetch the CRX3 form with `prodversion` matching the Chrome version the shim
  reports (156 today);
- verify the CRX3 signature and `crx_id`/proof-key binding before unpacking;
- install the same prepared bundle as a local file, marked `.store` for update
  checks;
- check the store's `updatecheck` reply on launch and replace a store bundle
  when its version differs, reloading it in every Space where it was enabled.

The in-page "Add to Chord" relay is **not** part of this decision. It depends
on store markup and is a separate UI slice. Chord does not proxy or host the
store, and does not claim the store endorses Chord.

## Consequences

- Store extensions install with Chrome's id, origin and update identity.
- A store outage or markup change affects only install/update, not local files.
- Store-page integration and real-extension compatibility remain M9c/M9e.
- BROWSER_SPEC §4.7's "no CWS" sentence is superseded by this ADR.
