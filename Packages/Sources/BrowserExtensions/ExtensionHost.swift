import BrowserCore
import BrowserEngine
import Foundation

/// What the rest of the app is allowed to know about the extension subsystem.
///
/// WebKit-free by construction: a `Space` goes in, plain values come out, and
/// the one thing the engine needs — the per-Space controller — leaves through
/// `BrowserEngine`'s opaque `ExtensionControllerHandle`, never a raw `WK*`
/// type. This is the §7.1 boundary, amended for M7 to "the engine layer is the
/// WebKit boundary." See ADR 011.
///
/// M7 grows this protocol phase by phase (load/enable/disable, actions,
/// permissions). At 7.1 it carries only what the seam needs: preparing a
/// Space's controller so the engine can attach it.
@MainActor
public protocol ExtensionHost: AnyObject, ExtensionControllerProviding {
    /// Ensures a Space has a live extension controller and returns its handle.
    ///
    /// Idempotent: the same Space yields the same controller for the app's
    /// lifetime, which is what makes extension storage for that Space stable.
    /// Until a Space is prepared it has no controller, and
    /// `extensionControllerHandle(for:)` returns `nil` for it — so an
    /// extension-free Space costs nothing.
    @discardableResult
    func prepare(_ space: Space) -> ExtensionControllerHandle

    /// Spaces that currently have a controller.
    var preparedSpaceIDs: Set<UUID> { get }
}
