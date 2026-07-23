# 004 — No shared `WKProcessPool`

**Status:** accepted (M1) — deviates from BROWSER_SPEC 6.2

BROWSER_SPEC 6.2 says to share one `WKProcessPool` per Space and never create
one per tab. That advice is now obsolete: Apple deprecated the entire type in
macOS 12, and the deprecation message is explicit — "Creating and using multiple
instances of WKProcessPool no longer has any effect."

Process sharing is governed by the website data store, not by an object we pass
around. Setting `configuration.processPool` today buys nothing but a deprecation
warning, and 7.6 requires the project to build warnings-as-errors from day one.
So the property is not set, and a comment at the former call site records why so
the next reader does not "fix" the omission.

The underlying intent of 6.2 is preserved and still matters: don't build
per-tab configuration state. `WebKitEngine` reuses one `WKWebViewConfiguration`
template and copies it per view, which is what actually keeps view creation
cheap and avoids recompiling content rule lists later.

When Spaces arrive in M2, isolation comes from
`WKWebsiteDataStore(forIdentifier:)` — the API the spec already names in 3.3 —
and not from process pools. BROWSER_SPEC 6.2 should be updated to drop the
process-pool sentence.
