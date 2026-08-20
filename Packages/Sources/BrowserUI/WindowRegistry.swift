import AppKit
import BrowserStore

/// Maps a `WindowState` to the `NSWindow` showing it, so an AppKit-side caller
/// (Little Chord promotion) can bring the *focused* window forward after the store
/// has decided a tab lands there.
///
/// `WindowState` is a pure, AppKit-free type (it lives in `BrowserStore`), so the
/// association cannot live on it. It lives here, in the UI layer where `NSWindow`
/// already belongs, keyed by object identity and held weakly so a closed window's
/// entry resolves to nil (and is swept on the next lookup) rather than leaking.
@MainActor
enum WindowRegistry {
    private struct Entry {
        weak var window: NSWindow?
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    /// Records (or refreshes) the `NSWindow` a `WindowState` is presented in.
    static func associate(_ state: WindowState, with window: NSWindow) {
        entries[ObjectIdentifier(state)] = Entry(window: window)
    }

    /// The live `NSWindow` for a `WindowState`, or nil if it has none (or closed).
    /// Compacts any entries whose windows have gone away while we are here.
    static func nsWindow(for state: WindowState) -> NSWindow? {
        entries = entries.filter { $0.value.window != nil }
        return entries[ObjectIdentifier(state)]?.window
    }
}
