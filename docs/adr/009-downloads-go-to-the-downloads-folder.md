# 009 — Downloads go straight to ~/Downloads

**Status:** accepted (M4, 2026-07-23)

## Context

`WKDownloadDelegate`'s one required method,
`download(_:decideDestinationUsing:suggestedFilename:)`, must return a writable
file URL — one that does not exist, in a directory that does. Returning nil
cancels the download.

The app is sandboxed. Before M4 it held only
`com.apple.security.files.user-selected.read-write`, which grants access to
paths the user picks in a panel and nothing else. That entitlement alone cannot
reach `~/Downloads`, so every destination callback would have failed and no
download could ever have started.

Three options were on the table:

1. Add `com.apple.security.files.downloads.read-write` and save silently.
2. Show an `NSSavePanel` per download, keeping the sandbox untouched.
3. Ask once, persist a security-scoped bookmark, then save silently.

## Decision

Option 1. `com.apple.security.files.downloads.read-write` is added to
`Chord.entitlements`, and downloads land in `~/Downloads` with no prompt.

This matches what Safari, Chrome, and Arc do, and it is the interaction model
this browser is replicating — a modal on every download is not it. The
entitlement widens the sandbox by exactly one well-known folder that exists for
this purpose, which is a smaller cost than the bookmark machinery option 3 would
add to a tool maintained by one person.

Filename collisions are resolved in `DownloadNaming.uniqueURL` (`report.pdf` →
`report-1.pdf`). This is not a nicety: WebKit rejects a destination that already
exists, so an unresolved collision fails the download outright. The suggested
filename comes from web content and is reduced to its last path component
first, so `../../etc/passwd` becomes `passwd` and cannot escape the directory.

## Consequences

- No save panel, and no way to choose a destination per download. If that is
  ever wanted, it is additive — the resolver is one function.
- `swift test` runs **unsandboxed**, so the end-to-end download test proves the
  WebKit wiring but says nothing about the entitlement. That was verified by
  hand against the real app instead, and must be re-verified by hand whenever
  entitlements change. No automated test covers it.
- If the entitlement is ever dropped, the failure appears as
  "Downloads folder unavailable" from the directory-creation guard rather than
  anywhere more obviously entitlement-shaped.
