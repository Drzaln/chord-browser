# Design proposal — built-in password vault

**Status: proposal, not accepted. Nothing is built.** §11 forbids starting
without an explicit go-ahead; this exists to be argued with first. Open questions
are at the end and three of them change the shape of the work.

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
  account, with `kSecAttrAccessibleWhenUnlocked`. This is the boring path and it
  is available on a free personal team — no entitlement, no paid membership.
- **No app-level master password.** A second password protects against a threat
  the Keychain already covers, and a home-grown KDF is exactly the sort of crypto
  this project should not be writing.
- **Touch ID gate, decided 2026-07-31.** The vault locks on idle and on
  screen-lock, and unlocking is `LAContext` biometry with device-passcode
  fallback. Two ways to build it, and the choice is not cosmetic:
  - *App-level gate* — we ask `LAContext` ourselves, then read an ordinary
    Keychain item. Simple, testable, and honest about its limit: the item is
    readable without biometry by anything running as the user, so the gate is a UI
    lock, not a cryptographic one.
  - *Access-control gate* — the item itself carries
    `SecAccessControlCreateWithFlags(..., .userPresence, ...)`, so **the Keychain**
    refuses to hand it over without biometry. Stronger, and it survives our own
    bugs, but every read becomes an async authenticated call, and the failure modes
    (no enrolled biometry, denied auth, changed biometric set) have to be handled
    on every fill.

  Recommendation: **access-control**, because a lock that our own code can bypass
  by accident is the kind that quietly stops being a lock. Cost: V7 stops being a
  bolt-on and has to be designed into V1's storage shape, since it changes how
  items are written. That is a reason to decide it now rather than later, which is
  what this note does.
- Auto-lock needs a **timeout preference** (default: 15 minutes idle) and must
  also trip on `NSWorkspace.willSleepNotification` and screen lock.
- Consequence to state out loud even with the gate: while unlocked, a filled
  password is plaintext in the page's DOM, and anything running as you can drive
  the same APIs. This raises the bar; it does not make the vault a safe.

## How filling actually works

1. `PasswordFormMonitor` (user script, `atDocumentStart`, **main frame only**)
   classifies fields on load and on DOM mutation: username-ish, password,
   new-password, one-time-code. Pure heuristics — `autocomplete` attributes first,
   then type/name/id/label signals — and the heuristic itself lives in
   `BrowserCore` as a pure function, so it is unit-testable against a corpus of
   real login markup with no browser involved.
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

## If this is approved

The first commit is V1 and nothing else, per §8's one-milestone-at-a-time rule,
and it stops for review. Before writing it, two things need checking against the
SDK rather than assumed, in the spirit of §11:

- That a `.userPresence` access-control item behaves under **App Sandbox +
  Hardened Runtime in a Release build** — `swift test` is unsandboxed and cannot
  tell us. This is the microphone trap (ADR 014) waiting to happen again.
- Whether a keychain access group is needed at all for a single sandboxed app with
  no paid team, or whether the default application group is enough. If it is not,
  the whole storage half needs rethinking before V1 is written, not after.
