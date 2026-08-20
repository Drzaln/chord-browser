# 005 — A separate `ChordStore` package

**Status:** accepted (M1) — extends BROWSER_SPEC 3.5

BROWSER_SPEC 3.1 names four layers, of which Store is one: "Observable app
state, commands". The package list in 3.5 has six entries and no home for it.
Left as-is, the store would have to live in `ChordUI` (making view code own
app state) or in `ChordApp` (making it unreachable from the views that need
it). Both defeat 3.1's own layering.

So there is a seventh local target, `ChordStore`, holding `TabStore`,
`PaneRuntime`, and `AppEnvironment`. It imports Core, Engine, and Persistence;
`ChordUI` imports Core, Engine, and Store. Dependencies still flow downward
only, and the compiler still enforces the boundaries.

`ChordUI` importing `ChordEngine` is worth stating plainly, because 3.5
lists UI as importing Core alone. It has to: the surface it renders comes from
the engine. The rule that actually matters is the one in bold in 3.5 — **UI must
not import WebKit** — and that holds. `AnyWebSurface` is the entire vocabulary
UI has for web content, and no `WK*` type appears anywhere in the engine's
public interface.

The packages are also organised as one `Package.swift` with seven targets rather
than seven separate manifests. Target dependencies give identical compile-time
enforcement with one file to maintain, and a local package boundary buys nothing
extra when nothing is published.
