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

    /// Loads an installed bundle into a Space's controller (7.3). Enforces
    /// **MV3 only** — an MV2 bundle throws `unsupportedManifestVersion` — and
    /// prepares the Space's controller if it was not already. The underlying
    /// `WKWebExtensionContext` stays inside the host; the caller gets a
    /// WebKit-free descriptor.
    @discardableResult
    func load(_ installed: InstalledExtension, in space: Space) async throws -> LoadedExtension

    /// Unloads a previously loaded extension from a Space. A no-op if it was not
    /// loaded there.
    func unload(slug: String, in space: Space) throws

    /// Extensions currently loaded in a Space, sorted by slug.
    func loadedExtensions(in space: Space) -> [LoadedExtension]

    // MARK: - Toolbar actions (7.5a)

    /// The default toolbar-action snapshot for every extension loaded in a
    /// Space, sorted by slug. WebKit-free: the live `WKWebExtensionAction` stays
    /// inside the host (ADR 011). Rebuilt from the current action state each
    /// call, so it always reflects the latest label / badge / enabled-ness.
    func actions(in space: Space) -> [ExtensionActionSnapshot]

    /// Called on the main actor whenever an extension updates its action (badge,
    /// icon, enabled-ness), so the Store can invalidate and the UI re-read
    /// `actions(in:)`. Set by `AppEnvironment`; the host holds it, not a list of
    /// observers.
    var onActionsChanged: (@MainActor () -> Void)? { get set }

    // MARK: - Tab lifecycle (7.3b)
    //
    // The Store calls these as tabs open, activate, and close, so each Space's
    // controller can fire the matching WebExtensions events. WebKit-free (UUIDs
    // only); a no-op for a Space with no controller.

    func extensionTabDidOpen(_ tabID: UUID, inSpace spaceID: UUID)
    func extensionTabDidActivate(_ tabID: UUID, previous previousTabID: UUID?, inSpace spaceID: UUID)
    func extensionTabDidClose(_ tabID: UUID, inSpace spaceID: UUID)
}
