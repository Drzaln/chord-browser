import BrowserCore
import Foundation

/// What kind of window a claiming scene should get.
///
/// A separate type rather than a `Bool` because the latch below is read once and
/// a bare optional Bool at the call site reads as "private or not stated", which
/// is exactly the ambiguity that must not exist here.
public enum WindowKind: Sendable, Equatable {
    case normal
    /// The associated URL is what the window's first tab opens, for "Open Link
    /// in New Private Window". Carried *on the case* rather than in a second
    /// stored property, because the latch is read-and-cleared in one step and
    /// two properties cleared by the same `defer` are two things to keep in
    /// step — the first cut cleared the URL before the caller could read it.
    case `private`(url: URL? = nil)
}

/// Private (incognito) windows — see `docs/design` notes in CHECKPOINT.
///
/// **A private window is a window locked to a private `Space`**, and that one
/// decision is what makes the feature small: everything durable in this app is
/// already Space-scoped — `Tab.spaceID`, history, site permissions, the
/// extension host's window-per-Space model, and the `WKWebsiteDataStore` itself,
/// which `DataStoreRegistry` already builds as `.nonPersistent()` when
/// `Space.isPrivate` (§3.3, ADR 006). So the single predicate below is the guard
/// every suppression point uses, and `WindowState.isPrivate` exists only for the
/// UI and for teardown — persistence never consults it.
@MainActor
extension TabStore {

    // MARK: - The latch

    /// Marks the *next* window a scene claims as private.
    ///
    /// The channel is a one-shot latch rather than `WindowGroup(id:for:)` for
    /// two reasons, both learned from how this app already opens windows:
    /// SwiftUI **dedupes** value-based windows, so a second private window with
    /// an equal value would front the first instead of opening; and a
    /// presentation value participates in **scene restoration**, so macOS would
    /// hand "private" back at launch — the one thing that must never resurrect a
    /// private session.
    ///
    /// The asymmetry is deliberate: a normal window opening private by mistake
    /// is harmless, a private one opening normal would silently write history.
    /// So the latch is consumed by exactly one claim and never inferred.
    /// - Parameter url: what the window's first tab should open, for "Open Link
    ///   in New Private Window". Nil means the ordinary new-tab destination.
    public func markNextWindowPrivate(opening url: URL? = nil) {
        pendingWindowKind = .private(url: url)
    }

    /// Reads and clears the latch. `.normal` when nothing asked.
    func takeWindowKind() -> WindowKind {
        defer { pendingWindowKind = nil }
        // The primary window is never private: it is the session, it owns
        // `restore()`, and ⌘⇧N cannot be pressed before it exists.
        guard hasClaimedPrimary else { return .normal }
        return pendingWindowKind ?? .normal
    }

    // MARK: - The predicate

    /// Every suppression point asks one of these three.
    func isPrivate(spaceID: UUID?) -> Bool {
        guard let spaceID else { return false }
        return spaces.first { $0.id == spaceID }?.isPrivate ?? false
    }

    func isPrivate(paneID: UUID) -> Bool {
        isPrivate(spaceID: spaceID(forPane: paneID))
    }

    func isPrivate(tabID: UUID) -> Bool {
        isPrivate(spaceID: tabs.first { $0.id == tabID }?.spaceID)
    }

    /// The Spaces a normal window may show, and the only ones ever written to
    /// disk.
    ///
    /// A private Space still lives in `spaces`, because dozens of call sites
    /// resolve a Space from there (`activeSpace(in:)`, the engine's
    /// `surface(for:in:)`, `moveTab`). Keeping it in one list and filtering the
    /// two places that *enumerate* — display and persistence — is a far smaller
    /// surface to get right than a parallel collection every resolver would have
    /// to learn about.
    public var visibleSpaces: [Space] {
        spaces.filter { !$0.isPrivate }
    }

    // MARK: - Lifecycle

    /// Builds the throwaway Space a private window owns.
    ///
    /// Its own graphite stops, so `SpaceTheme` renders it through the ordinary
    /// cached path with no new theming API, and the window reads as a different
    /// place at a glance.
    func makePrivateSpace() -> Space {
        Space(
            name: "Private",
            iconSymbol: "eye.slash",
            gradient: Self.privateGradient,
            sortIndex: (spaces.map(\.sortIndex).max() ?? -1) + 1,
            isPrivate: true
        )
    }

    static let privateGradient: [ColorHex] = ["#3A3D4A", "#23252E"]

    /// Ends a private session: the window is going away, so its Space, its tabs,
    /// its live views, and its in-memory cookie jar all go with it.
    ///
    /// **Order matters.** The window is dropped from the registry by the caller
    /// *before* this runs, because the `reconcileWindows()` at the end would
    /// otherwise re-home a live window onto a Space that is being deleted.
    func tearDownPrivateSession(_ spaceID: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }),
            spaces[index].isPrivate
        else { return }
        let space = spaces[index]

        for tab in tabs where tab.spaceID == spaceID {
            for pane in tab.panes {
                // Discarding what `evict` returns is the point: capturing
                // interaction state here is precisely what must not happen.
                engine.evict(paneID: pane.id)
                runtimes[pane.id] = nil
            }
            extensionHost?.extensionTabDidClose(tab.id, inSpace: spaceID)
        }

        tabs.removeAll { $0.spaceID == spaceID }
        folders.removeAll { $0.spaceID == spaceID }
        spaces.remove(at: index)
        lastSelectedTabBySpace[spaceID] = nil
        pendingCredentialSpaces = pendingCredentialSpaces.filter { $0.value != spaceID }

        Task { [engine] in
            // For a private Space this reclaims nothing from disk — there is
            // nothing there — but it drops the cached `.nonPersistent()` store,
            // which is what actually ends the session in memory.
            try? await engine.removeData(for: space)
        }

        reconcileWindows()
        scheduleSave()
    }
}
