# 024 — Site overrides are generated CSS, not a styling engine

**Status:** accepted

Requests for "make this site readable" are concrete and repeated: hide the
right-hand rail on a docs site, kill a webfont, widen a column, drop a sticky
header. Three designs could serve that — a theme model with colour and font
fields, a CSS/JS box, or a picker that turns clicks into selectors. Shipping all
three is how this becomes a browser inside the browser.

**Decision: one record per site — `(pattern, css, js, hiddenSelectors,
enabled)` — and no theme model at all.** If theme pickers ever ship, they are
generators that append CSS to that field. Hiding compiles to CSS as well:
`display:none !important` on a selector list, in a `<style>` injected at document
start.

That last choice is the load-bearing one. Hiding by script means a
`MutationObserver` polling a DOM the site rewrites, which is the exact cost the
YouTube blocker already pays and which is already a standing maintenance item
(ADR 013). A stylesheet survives SPA re-render for free because it outlives the
DOM it styles. JS stays in the record only for behaviour CSS cannot express —
user-supplied, page world, trusted-local, the same trust level as a snippet
pasted into the Web Inspector. It can read that site's cookies; that is fine for
code the user typed into their own browser, and it is why v1 has no import
format and no remote source of overrides.

The ruleset is serialized into `WKUserScript`s built in
`WebKitEngine.makeContentController()`, alongside the other monitors, and guards
on `location.host` before doing anything. There is one stylesheet script and one
script per override that has JS — **not** one script for everything. Inlining
every override's JS into the CSS script would mean a single syntax error in
anybody's user script stops the whole script from parsing, taking every site's
CSS down with it. Separate scripts contain the damage to the broken override. Per-space data isolation (§3.3) leaves
no shared origin a document could ask, and a synchronous message on every
document start would cost a round trip before first paint. When no enabled
override exists the script is not installed at all — the same frugality as the
developer-mode-only DRM script.

User JS is inlined in its own generated script rather than `eval`'d, because an
injected `eval` is subject to the page's CSP, and a site that forbids it would
silently swallow every override. Each rule's JS is wrapped in a try/catch inside
its own function so a throwing override cannot break the page.

Edits apply on the **next load**, and the editor says so with a Save button and
"Reload the page to see it". That is the contract the per-domain User-Agent map
already set (§4.9). Rebuilding configurations on save would recompile content
rule lists (6.2) and tear down live web views for a cosmetic change. Saves are
explicit rather than per-keystroke for the same reason: each save rebuilds the
injected script on every live view.

The **element picker** is evaluated into the current document rather than
installed as a user script, because the point is to pick on the page that is
already open. It draws its own highlight box and label, and on click writes the
shortest selector it can defend — id, then a stable `data-*`/`aria-*` attribute,
then an `nth-of-type` path capped at five levels — into `hiddenSelectors`, not
into the CSS box, so the editor stays readable. It is main-frame only: it cannot
reach into a cross-origin iframe (the YouTube player, an embedded editor), which
is a WebKit limitation and documented as such.

Scope limits, written down so they are not read as bugs: no shadow-DOM piercing;
overrides are global rather than per-Space (a site should look the same in every
Space, and per-Space multiplies the editing for no ask that has been made);
opaque origins and `file:` URLs are excluded; there is no sync or export.

Storage is the `UserDefaults` preference `prefs.siteOverrides`, beside the
routing rules — choices tied to no Space, and small (a few KB at most).

Tests: CSS emission from a selector list, invalid selectors skipped, host
matching, "no enabled overrides → no scripts", generated-script contents and
separation (CSS script cannot be broken by a JS syntax error), escaped patterns,
pick-result parsing and the wrong-site refusal, and store round-trip/persistence.
