# 017 — Extension bundles are verified at install; untrusted ones warn, not block

**Status:** accepted (post-M7, shipped 2026-08-07)

## Context

`WKWebExtension` loads whatever bundle it is handed and performs **no signing
checks of its own**. The installer's only transform was stripping the CRX
signature header (`ExtensionArchive`) — the signature was *discarded, never
looked at*. A `.crx`/`.xpi`/`.zip` someone gets you to open therefore ran with
full extension privileges, attributed to no one.

The Chrome Web Store solves this with a store that signs bundles it reviewed.
Chord has no store, and will not attempt CWS install flows (BROWSER_SPEC §4.7
— CWS blocks non-Chrome agents). So the signing check, if any, is ours.

## Decision

**Verify every bundle's signature at install, and make the verdict a warning,
not a gate** — warn-but-install:

- A CRX2/CRX3 whose signature cryptographically validates against the public key
  it **embeds** is `.verified`: internally consistent (not tampered since it was
  signed) and attributable to whoever holds the matching private key — but not
  vouched for.
- If that embedded key is in a **pinned** set the app trusts, the verdict
  upgrades to `.trusted`. The pinned set is empty today; the plumbing exists so a
  future store key slots in without re-designing the check.
- A signature that fails to validate (tampered, or a swapped key) is `.tampered`
  and never silent.
- A plain `.xpi`/`.zip` carries no signature — `.unsigned`.
- An unparseable header is `.unsupported`.

All non-`.trusted`/non-`.verified` verdicts are surfaced, not blocked: an orange
warning on the extension row, a message at install time, and a confirmation
before an unverified extension is enabled. This is the developer-friendly
equivalent of Chrome's "unpacked extension" trust model, chosen over
block-and-refuse because signed-only installs would strand the personal `.xpi`
bundles this browser exists to load.

## Where the check lives

A new package, **`BrowserCrypto`** — the second Security/CryptoKit importer
(after `BrowserSecrets`). It is the application of ADR 011's
one-OS-framework-per-target rule to signing: the vault owns Keychain/LocalAuth,
crypto owns signing; neither bleeds into the WebKit layers. `BrowserExtensions`
depends on it so `ExtensionInstaller` stamps the verdict before the header is
stripped.

The verdict is **persisted** as `Extensions/<slug>.verification` (the status
enum's raw value), because the header that proves it is removed at install — a
re-verify of the stored ZIP would always read `.unsigned`.

## What "verified" does and does not mean

The honest reading is in the type: `.verified` proves a bundle is what its
signer shipped; it does not vouch for that signer. With no pinned store key,
`.verified` is the best case today and it still gets a row icon. `.trusted` is
unreachable until a signer is actually pinned — the code refuses to fake it.

## Consequences

- **CRX3 parsing is real.** The header is a protobuf (`CrxFileHeader` /
  `SignedData`); a minimal bounds-checked protobuf reader lives in `BrowserCrypto`
  and verifies the RSA-SHA256 proof over `signed_header_data`, plus the ZIP
  against `SignedData.sha256_with_rsa`. ECDSA-only headers (unsupported) read as
  `.unsupported`, never as verified.
- **No paid Apple identity involved** — this needs only a public key, unlike the
  vault's Keychain hardening (ADR 016's `-34018` blocker), which stays out.
- **The UI copy is a test.** Status → warning text is pinned in a `BrowserUITests`
  suite so a verdict can never silently render as trusted.
- **No signing of our own** — a future feature (signing bundles we distribute)
  would need a private key and a distribution story, both out of scope here.
