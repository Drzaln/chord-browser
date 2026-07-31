# Design proposal — built-in password vault

**Status: accepted and shipped, V1–V7 (2026-07-31).** The text below is kept as
written, because the reasoning is what makes the code readable; where reality
turned out differently it is marked, in place, with what was measured.

## Why this exists

Chord has no password story at all today. Safari's AutoFill is Safari's, not
WebKit's — there is no fill hook, no keychain bridge, and no credential API in any
`WKWebView` header. The extension route is closed too: Bitwarden's MV3 build dies
at startup because Apple's runtime does not implement `chrome.offscreen`
(CHECKPOINT, 2026-07-31), and most MV3 managers use it for the same
clipboard/crypto work. Passkeys are closed for a third reason — WebKit reports no
platform authenticator in a plain `WKWebView`, and the native path needs an
Associated Domains entitlement per relying-party domain, which is impossible for
sites you do not own.

So: build it, or type passwords by hand forever.

## What it is, and is not

**Is:** save a username and password per site, on your ask; offer them back on
that site, on your ask; manage and delete them in Settings.

**Is not**, and these are load-bearing exclusions rather than a wish list:

- **No sync.** §1 rules out cross-device sync; this is the last subsystem that
  should break that.
- **No passkeys.** Not possible (above). Do not let the vault imply otherwise.
- **No credit cards, addresses, notes, TOTP.** A password vault that grows into a
  wallet is a second product. TOTP is the only one worth revisiting later.
- **No import from other managers in v1.** A CSV importer is a small, additive
  follow-up, and a bad one silently mangles a vault.
- **No filling into cross-origin iframes.** The classic credential-theft vector;
  excluded permanently, not deferred.

## The threat model, stated plainly

This subsystem is different from every other in the project: a bug here costs the
user their accounts, not a reload. Worth being explicit about what it does and
does not defend against.

**Defends against:** another local app or a stray script reading credentials off
disk; a page stealing a credential for a *different* site; a shoulder-surfer
reading a plaintext vault file; the browser filling into a look-alike origin.

**Does not defend against:** malware running as you with your Mac unlocked (it can
ask the Keychain the same way we do); a compromised WebKit content process on the
exact origin a credential belongs to at the moment it is filled; you typing your
password into a phishing page yourself. Saying so up front is what stops the
design from pretending an unachievable guarantee.

**Non-negotiable rules**, each of which is a test:

1. Fill only on an **exact origin match** — scheme, host, and port. No parent-domain
   matching, no "close enough" hosts.
2. **HTTPS only** for both save and fill, with no exception for `localhost`
   beyond an explicit developer opt-in.
3. **Main frame only.** Never fill inside an iframe, same-origin or not, in v1.
4. **Never fill without a user gesture.** No fill on page load, ever — that alone
   defeats the invisible-form harvesting attack.
5. Never fill a **hidden or off-screen** field, and never a field the page moved
   under the pointer after the click began.
6. Secrets never touch the model layer as plaintext beyond the moment of use, and
   never enter `browser.sqlite`, logs, or `interactionState`.

## Where the code goes

The module rules (§3.5) decide most of this. One new package, for the same reason
`BrowserExtensions` exists (ADR 011): a distinct OS-framework boundary earns its
own target rather than being folded into a package doing another job.

```
BrowserSecrets/       NEW. The ONLY importer of Security / CryptoKit /
                      LocalAuthentication. Keychain access, encryption,
                      the unlock gate. No WebKit, no UI, no SQLite.
BrowserCore/          Credential *metadata* value types, origin-matching rules,
                      form-field classification heuristics — all pure, all
                      testable without a keychain or a web view. Foundation only.
BrowserPersistence/   Metadata rows only (origin, username, timestamps, last-used
                      Space). NEVER the secret.
BrowserEngine/        The page-side half: a user script that finds login forms,
                      reports them, and fills on command. Same family as
                      MediaActivityMonitor / NotificationBridge (ADR 008, 015).
BrowserStore/         Policy: what to offer, when to prompt, what to remember.
BrowserUI/            The save bar, the credential picker, Settings management.
```

The split that matters: **metadata in SQLite, secret in the Keychain**, joined by
a stable id. It keeps a vault backup, a `.recover` pass, or a stray `sqlite3`
session from ever containing a password, and it means the existing "clear browsing
data" paths cannot accidentally take the vault with them.

## Storage and crypto

- One Keychain item per credential, `kSecClassInternetPassword`, keyed by server +
  account, with `kSecAttrAccessibleWhenUnlocked`. **Measured against a sandboxed,
  Hardened-Runtime, ad-hoc-signed Release build on 2026-07-31** rather than
  assumed — `swift test` runs unsandboxed and cannot see any of this:
  - add, read, and round-trip all return `errSecSuccess`. No
    `keychain-access-groups` entitlement is needed, and none is added.
  - the item survives **relaunch** and, importantly for a project rebuilt several
    times a day, a **rebuild with a different ad-hoc code signature** — access is
    by bundle id inside the sandbox container, with no re-authorisation prompt. A
    vault would not be lost on every build.
- **No app-level master password.** A second password protects against a threat
  the Keychain already covers, and a home-grown KDF is exactly the sort of crypto
  this project should not be writing.
- **Touch ID gate, decided 2026-07-31 — app-level, because the stronger form is
  not available to us.** The recommendation here was originally an
  *access-control* gate: mark the item with
  `SecAccessControlCreateWithFlags(..., .userPresence, ...)` so the **Keychain**
  itself refuses to hand it over without biometry, and our own bugs cannot bypass
  the lock. Measured against a Release build, that is impossible on this signing
  setup:

  ```
  SecAccessControlCreateWithFlags: ok
  SecItemAdd (guarded): -34018 (A required entitlement isn't present.)
  ```

  `errSecMissingEntitlement`. Biometry itself is fine — `canEvaluatePolicy`
  returns true and Touch ID is present — it is the protected *item* that is
  refused, because that path needs the data-protection keychain and an
  application-identifier entitlement, which comes with a real signing identity.
  The app is ad-hoc signed with `TeamIdentifier=not set` (§Requirements: no paid
  account), so the entitlement cannot be had.

  So the gate is **app-level**: we evaluate `LAContext` ourselves, then read an
  ordinary Keychain item. Its limit must be stated wherever the feature is
  described, not buried here — *the lock is a UI lock, not a cryptographic one.*
  It stops someone sitting at your unlocked Mac from reading your passwords out of
  Chord. It does not stop code running as you, which can read the same item
  without ever asking us.

  If a paid account ever appears, moving to access-control items is a migration
  (re-write every item with the flag), not a redesign — worth leaving a note in
  the storage layer to that effect.
- **Ad-hoc signing costs a Keychain prompt after every rebuild (found 2026-07-31,
  live).** A saved password read back by a *rebuilt* app raises the system
  "Chord wants to use your confidential information stored in
  com.rizal.browser.vault" dialog, asking for the login-keychain password. The
  item's ACL trusts the code identity that created it, and an ad-hoc signature
  changes on every build. The V1 probe missed this: it tested one rebuild and got
  away with it.

  **A stable self-signed certificate was tried and abandoned (2026-07-31).** The
  theory was sound — signing with one certificate makes the designated
  requirement `identifier "com.rizal.browser" and certificate root = H"…"`, which
  is identical before and after a rebuild, so the ACL keeps matching. That part
  worked. What killed it was the **Debug bundle's nested `Chord.debug.dylib`**:
  re-signing the app leaves the dylib on its old signature, and dyld then refuses
  it with *"mapping process and mapped file (non-platform) have different Team
  IDs"*, which surfaces only as "Chord cannot be opened because of a problem"
  (the real reason is in `~/Library/Logs/DiagnosticReports`). Signing the nested
  dylibs first did **not** fix it either, and recovering the bundle needed a full
  `xcodebuild clean build` — manual re-signing could not put it back. Doing this
  properly would mean changing the project's signing settings so Xcode signs
  everything consistently, which is a `project.pbxproj` change this repo's
  workflow keeps out of commits.

  **Accepted instead: click "Always Allow" once per build.** It is one dialog
  after each rebuild and none at all for a build you keep. Worth naming the cost
  honestly — it trains the habit of approving keychain dialogs, which is a poor
  habit for a password manager to instil, and it is the reason to revisit signing
  if the vault ever ships to anyone else. An allow-any-application ACL remains
  refused: it would hand the vault to every process on the machine.

- Auto-lock needs a **timeout preference** (default: 15 minutes idle) and must
  also trip on `NSWorkspace.willSleepNotification` and screen lock.
- Consequence to state out loud even with the gate: while unlocked, a filled
  password is plaintext in the page's DOM, and anything running as you can drive
  the same APIs. This raises the bar; it does not make the vault a safe.

## How filling actually works

1. `PasswordFormMonitor` (user script, `atDocumentStart`, **main frame only**)
   *collects* a descriptor per input — type, `autocomplete`, name, id, label,
   visibility — and posts them. It makes no decisions: `LoginFormClassifier` in
   `BrowserCore` does, so the judgement is testable against captured markup with
   no browser involved.

   **What a spike against real sites found (2026-07-31)**, each of which would
   break a spec-reading implementation:

   | Site | Reality |
   |---|---|
   | Reddit | **Zero inputs in the light DOM** — 46 shadow hosts; the collector *must* pierce open shadow roots or the page is invisible |
   | Google | A **hidden decoy** password field on the username step |
   | GitHub | Three invisible `required_field_*` **honeypots**; filling one flags a bot |
   | Instagram / Facebook | `autocomplete="username webauthn"` — **multi-token** |
   | Mixpanel | Password field present but invisible until the email step passes |
   | npm | **No `autocomplete` at all**; only name and label |
   | GitLab | Served no form at all to an automated WKWebView (bot wall) |

   Two consequences for the collector: it must **walk open shadow roots**, and it
   must report **live visibility** (rects + computed style), because ignoring
   invisible fields is what defeats the decoy, the honeypots, and the
   not-yet-revealed field in one rule.
2. If a credential exists for the exact origin, the field gets a small affordance.
   Clicking it — a user gesture, rule 4 — asks the store, which asks
   `BrowserSecrets`, which returns the secret for exactly one fill.
3. The script sets the values and dispatches `input`/`change` so frameworks
   notice. React-controlled inputs need the native setter dance, which is the one
   fiddly part and the reason this needs an e2e test rather than a unit test.

**Multiple accounts per origin is the normal case here, not an edge case** —
Spaces exist precisely so two Google accounts can be logged in at once. So: the
vault is **global**, not per-Space (a password is yours, not a Space's), but the
store remembers which credential was last used per `(Space, origin)` and offers
that one first. That gets the Work Space offering the work account without
partitioning the vault, and without a credential being invisible in the Space you
happen to be in.

## Capture

On submit — and on the SPA equivalent, a password field being cleared or removed
after a fetch — the script reports origin + username + whether the password
differs from a stored one. The store surfaces a **save bar**, never a modal, with
Save / Update / Never for this site. "Never" is itself a stored decision, keyed
per origin like the site permissions in ADR 014.

## Phases

Each is a commit with a done-when, in order, stopping for review — the M-series
shape that has worked here.

| Phase | Scope | Done when |
|---|---|---|
| **V1** | `BrowserSecrets` + models + origin matching, **written with the biometric access control from the start**. No UI. | A credential round-trips through the Keychain in a test, and the origin matcher rejects every near-miss in its table |
| **V2** | Metadata schema (v12) + repository | Migration has a fixture test; deleting a credential leaves no orphan row or orphan Keychain item |
| **V3** | Form detection user script + classification | The classifier scores a corpus of real login pages; the e2e server serves one and the script reports it |
| **V4** | Fill on gesture, incl. the framework-setter path | End-to-end against a real page in `BrowserE2ETests`: fill, submit, session established |
| **V5** | Capture + save bar | Logging in on the test page offers to save; relaunch offers it back |
| **V6** | Settings management: list, reveal (gated), delete, "never" list | Every stored item is visible and removable; nothing is reachable that the list does not show |
| **V7** | Lock UI + auto-lock policy (the storage half landed in V1) | Idle, sleep, and screen-lock all lock the vault; a denied or cancelled auth fills nothing and says so; no enrolled biometry falls back to the device passcode |

**All seven phases have shipped.** V7 landed 2026-07-31 and is verified live: see
`CHECKPOINT.md`, "Password vault V7". Two things in it differ from what this
document assumed and are worth reading before changing the lock:

- **`.unavailable` does not lock the vault out.** With no biometry *and* no device
  passcode there is nothing to authenticate against, so filling proceeds rather
  than becoming permanently impossible. Reveal still refuses, because that one
  puts a password on screen as text. A gate nothing can open stops only the owner.
- **The idle clock is evaluated lazily**, at each vault touchpoint and when the UI
  asks, never by a timer — a repeating timer writing observable state would redraw
  the chrome forever for a value that matters only at the moment of use (§6.4).

V1–V2 are quiet plumbing. **V3–V4 are the risky ones** — form heuristics are where
this kind of feature usually disappoints, and they are also where the e2e suite
(§10, real WebKit + real HTTP) actually earns its keep.

## What could make this a bad idea

- **It is the highest-consequence code in the project** and it is maintained by one
  person part-time. Every other subsystem fails soft; this one fails loud and
  expensive.
- **Form heuristics are a treadmill**, like the YouTube selectors (ADR 013) but
  with worse failure modes: a mis-detected field means a password typed into a
  visible input, or into the wrong site's form.
- **It cannot be tested the way the rest of the project is.** `swift test` runs
  unsandboxed, so the real Keychain behaviour under App Sandbox and Hardened
  Runtime has to be verified by hand against a Release build — the same trap the
  microphone hit (ADR 014).
- The honest alternative is a **standalone manager** (1Password, Bitwarden's
  desktop app) with copy-paste, or Safari for logins. That costs convenience and
  no engineering, and it is a legitimate answer to this whole document.

## Decided 2026-07-31

1. **Unlock: Touch ID gate with auto-lock.** No master password. Prefer the
   Keychain access-control form so the gate is enforced by the OS rather than by
   our own discipline — which pulls it into V1's storage shape (see above).
2. **Fill: click-to-fill only.** No fill on load, no focus-triggered dropdown in
   v1. Rule 4 stays absolute.
3. **Scope: one global vault**, with last-used memory per `(Space, origin)` so the
   right account is offered first without hiding any credential from any Space.

## Still open

4. Should **"never save for this site"** live with the ADR 014 site permissions —
   same table, same Settings section — or stay separate? Recommendation: same
   section in the UI, separate storage, since one is a capability grant and the
   other a vault preference. Not blocking: it is a V5 decision.

## Pre-V1 checks — done 2026-07-31

Both questions were answered by a temporary probe inside a **Release** build
(sandbox + Hardened Runtime + ad-hoc signature), then removed:

| Question | Answer |
|---|---|
| Is a `keychain-access-groups` entitlement needed without a paid team? | **No.** Plain items add and read cleanly, and survive relaunch *and* rebuild. |
| Does a `.userPresence` access-control item work? | **No** — `SecItemAdd` → `-34018 errSecMissingEntitlement`. Needs a real signing identity. |

Net effect on the plan: storage is plain Keychain items (V1 unchanged in shape),
and the Touch ID gate is app-level and honestly labelled. Nothing else moved.
