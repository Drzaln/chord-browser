# 016 — A built-in password vault, not an extension and not passkeys

**Status:** accepted (post-M7, V1–V6 shipped 2026-07-31). Full design, threat
model, and phase plan in [`docs/design/password-vault.md`](../design/password-vault.md).

## Context

Chord had no password story. The three obvious ways out were each measured shut
rather than assumed shut:

- **WebKit's own autofill is Safari's.** There is no fill hook, no keychain
  bridge, and no credential API in any `WKWebView` header.
- **Passkeys are unavailable.** A probe against real WebKit reported
  `isUserVerifyingPlatformAuthenticatorAvailable() == false` and a `create()`
  rejected with `NotAllowedError`, in a focused window. The native path needs an
  Associated Domains entitlement per relying-party domain, which is impossible for
  sites you do not own — so a paid account would not fix it either.
- **Password-manager extensions do not run.** Bitwarden's MV3 build fails with
  `WKWebExtensionContextErrorDomain` code 6 because its service worker calls
  `chrome.offscreen`, which Apple's runtime does not implement. Most MV3 managers
  use it for the same clipboard and crypto work.

So: build it, or type passwords by hand forever.

## Decision

A vault, split in two by design:

- **Metadata in SQLite** (`credential`, v12) — origin, username, timestamps.
- **The password in the macOS Keychain**, behind `ChordSecrets`, a new package
  that is the only importer of Security and LocalAuthentication for the vault
  (the same one-target-per-OS-boundary rule that gave `ChordExtensions` its own
  target, ADR 011; `ChordCrypto`, ADR 017, later became a second Security
  importer for extension signatures).

The split is the point: a database backup, a `.recover` dump, or a stray
`sqlite3` session can never contain a password.

The rules that are not negotiable, each of which is a test:

1. **Exact origin equality** — scheme, host, and port. No parent-domain matching.
   The near-miss table (subdomains, `example.com.evil.com`, punycode, scheme
   downgrade) is longer than the happy-path one.
2. **HTTPS only.** `CredentialOrigin.Policy` is `.strict` everywhere in the app;
   only the e2e harness relaxes it for its loopback server, and two tests exist to
   keep that from drifting.
3. **Never fill without a user gesture.** No fill on load, no fill on focus. There
   is exactly one caller, and it is a button.
4. **The origin is re-checked in the engine**, against the live `WKWebView`, at
   the moment of writing — a page can navigate between the offer and the click.
5. **Invisible fields are never filled.** One rule that defeats Google's decoy
   password field, GitHub's honeypots, and progressive disclosure at once.
6. **Secrets never enter observable state.** `CredentialSavePrompt` has no
   password field; the secret lives in a private side table keyed by prompt id.

## Consequences

- **The Touch ID gate is app-level, not Keychain-enforced.** The stronger form —
  an item the Keychain itself refuses without biometry — needs an
  application-identifier entitlement: measured, `SecItemAdd` returns `-34018`
  under the ad-hoc signing setup in force at the time. So the lock stops a person
  at an unlocked Mac, **not** code running as the user, and every description of
  it says so. (The app has signed with a real Apple Development identity since
  2026-08-20, so the guarded-item path is worth re-measuring.)
- **Filling uses the prototype value setter.** A direct `el.value =` is swallowed
  by React's value tracker: the field looks filled and the form submits an empty
  string. This is invisible on simple pages and breaks on most real ones.
- **Form detection is a treadmill**, like the YouTube selectors (ADR 013) but with
  worse failure modes. It is driven by a corpus captured from real login pages,
  and a site that changes its markup wants a re-capture, not a hand-edit.
- **A rebuild used to cost one Keychain dialog**, because an ad-hoc signature was
  a new code identity and the item's ACL trusted the old one. Signing with a
  stable self-signed certificate was tried and reverted (the Debug bundle's
  nested dylib makes re-signing unlaunchable). **Superseded 2026-08-20:** the app
  signs with a stable Apple Development identity (`DEVELOPMENT_TEAM =
  74XUPW85K2`), so the designated requirement survives rebuilds and the dialog no
  longer appears.
- **No sync, no passkeys, no wallet.** §1 rules out sync; the other two are listed
  above as unavailable and out of scope respectively.
