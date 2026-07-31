import Foundation

/// The notification an extension popup's open/close is broadcast on, so the
/// window it is anchored in can hold its revealed sidebar open while it is up.
///
/// A broadcast rather than a closure because the extension host is app-wide while
/// the sidebar being pinned belongs to exactly one window: a single closure would
/// be last-writer-wins across windows, and the second window to open would
/// silently take the first one's. The notification's `object` is the window the
/// popup is anchored in, as an opaque object — `BrowserStore` imports no AppKit,
/// so it never names `NSWindow`; `BrowserUI` casts and compares identity.
public enum ExtensionPopupVisibility {
    /// `userInfo` key carrying the `Bool`: true on open, false on close.
    public static let isVisibleKey = "isVisible"
}

extension Notification.Name {
    public static let extensionPopupVisibilityChanged = Notification.Name(
        "chord.extensionPopupVisibilityChanged"
    )
}
