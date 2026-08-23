import ChordCore
import Foundation
import Observation

/// The state that belongs to *one browser window*, split out of `TabStore` so a
/// second window can hold its own.
///
/// The dividing line is ownership, not layer: `TabStore` owns the world — tabs,
/// Spaces, folders, persistence, the sweep — and every window shows the same
/// one. This owns how a particular window is *looking* at that world: which
/// sections are collapsed, how wide its sidebar is, which sheet it is showing.
/// Verified against Arc, which is the model being replicated (§1): sidebar
/// collapse and width are per-window there, while the Space list is shared.
///
/// Selection (`selectedTabID`, `activeSpaceID`) belongs here too — Arc lets two
/// windows sit in different Spaces — but it is still on `TabStore`, because the
/// store's own mutations maintain it as an invariant (close, sweep, split) and
/// moving it needs a reconciliation rule for what window B does when window A
/// closes the tab it was showing. Deliberately a separate change.
///
/// Not `Codable` and not schema-bound: these are window preferences, not user
/// data, so they live in `UserDefaults` and have no place in a migration (§7.2).
@MainActor
@Observable
public final class WindowState {

    /// Backing store for the persisted preferences. Injected so tests get an
    /// in-memory store instead of the user's real defaults.
    @ObservationIgnored private let defaults: any PreferenceStore

    // MARK: - Selection

    /// The Space this window is looking at. Per-window: Arc lets two windows sit
    /// in different Spaces, and Cmd+1…9 moves only the focused one.
    ///
    /// Not persisted — which Space a window was in is window *layout*, and
    /// `restore()` picks the first Space until layout persistence exists.
    public internal(set) var activeSpaceID: UUID?

    /// The tab this window is showing, which is only ever one of its active
    /// Space's tabs.
    ///
    /// Two windows may hold the same id: the same tab shown twice is one tab and
    /// one web view, because a pane belongs to its Space, not to a window.
    public var selectedTabID: UUID?

    /// Whether the sidebar is collapsed to icons (4.1).
    ///
    /// Not in a `@State` because the menu command drives it too, and a view's
    /// `@State` is not reachable from `Commands` — the window reaches it through
    /// `@FocusedValue` instead.
    public var isSidebarCollapsed: Bool {
        didSet { Preferences.save(isSidebarCollapsed: isSidebarCollapsed, to: defaults) }
    }

    /// The user-configured width of the sidebar.
    public var sidebarWidth: CGFloat {
        didSet { Preferences.save(sidebarWidth: sidebarWidth, to: defaults) }
    }

    /// Whether the user is actively dragging to resize the sidebar. Volatile —
    /// it is a gesture, not a preference.
    public var isSidebarResizing: Bool = false

    /// An extension popup is on screen in this window. Volatile.
    ///
    /// It is here rather than in the view because it decides `isSidebarHeldOpen`,
    /// and because a popup belongs to one window (invariant 7b). Set from the
    /// `extensionPopupVisibilityChanged` broadcast, which carries the window the
    /// popup is anchored in.
    public var isExtensionPopupOpen: Bool = false

    /// Something is keeping a revealed sidebar on screen, so the auto-hide must
    /// not fire: a resize drag, a Space sheet, or an extension popup.
    ///
    /// One rule rather than four scattered checks. The popup case is the one that
    /// is not obvious: the popup is anchored to the sidebar-header button, so
    /// hiding the sidebar removes the anchor from the window and AppKit closes
    /// the popup — and moving the pointer into the popup is precisely what ends
    /// the hover that was keeping the sidebar revealed. Without this, an
    /// extension popup could not be used at all with a collapsed sidebar. The
    /// rename alert is the same shape: it is presented above the window, so the
    /// pointer leaves the sidebar the moment it opens, and an auto-hide firing
    /// then would drop the alert out from under the user.
    public var isSidebarHeldOpen: Bool {
        isSidebarResizing
            || editingSpaceID != nil
            || deletingSpaceID != nil
            || isExtensionPopupOpen
            || renamingTabID != nil
    }

    /// Presentation mode: the sidebar and reveal strip are hidden so the window
    /// shows only web content (non-spec: user-requested). This is the native
    /// substitute for "Share this tab" — WebKit has no tab-level screen capture,
    /// so the user shares the *window*, and this makes the window read as just
    /// the page. Volatile: a session mode, not a saved preference.
    public var isPresentationMode: Bool = false

    /// Whether this is a private (incognito) window — ⌘⇧N.
    ///
    /// Volatile and immutable, in the same class of state as
    /// `isPresentationMode`: a window is born private or is not, and nothing
    /// about it is ever written to disk. **Persistence never reads this** — the
    /// suppression guards all ask `TabStore.isPrivate(spaceID:)` instead, since
    /// a private *Space* is the thing that owns the tabs and the data store. See
    /// `TabStore+Private.swift`.
    public let isPrivate: Bool

    /// The throwaway Space this window owns, when it is private. Kept apart from
    /// `activeSpaceID` so teardown stays unambiguous.
    public internal(set) var privateSpaceID: UUID?

    /// The Spaces whose Pinned-tabs section is collapsed in *this* window
    /// (non-spec: user-requested). Per-Space and now per-window, so two windows
    /// in the same Space can disagree.
    public var collapsedPinnedSpaces: Set<UUID> {
        didSet { Preferences.save(collapsedPinnedSpaces: collapsedPinnedSpaces, to: defaults) }
    }

    /// The Space whose appearance is being edited, if any. Ephemeral UI state
    /// kept here — not in the sidebar — so its editor sheet is presented from
    /// `RootView` and survives the sidebar collapsing (and auto-hiding) beneath
    /// it. Not persisted.
    public var editingSpaceID: UUID?

    /// The Space being deleted, if any. Kept here for the same reason as
    /// `editingSpaceID`. Not persisted.
    public var deletingSpaceID: UUID?

    /// The tab whose rename alert is up, if any (non-spec: user-requested).
    ///
    /// Kept here for the same reason as `editingSpaceID`: the alert is presented
    /// from `RootView` so it survives the sidebar collapsing (and auto-hiding)
    /// beneath it, and it holds the sidebar open while it is on screen. Not
    /// persisted.
    public var renamingTabID: UUID?

    /// Whether the settings sheet is showing. Kept here for the same reason.
    public var isSettingsPresented = false

    /// Whether the History window is showing. Kept here for the same reason.
    public var isHistoryPresented = false

    /// Signed progress of an in-flight swipe between Spaces, in `[-1, 1]` (4.2).
    /// Positive is toward the next Space (higher `sortIndex`). Observed: the
    /// sidebar blends its gradient toward the neighbour's as this moves. Volatile
    /// and never persisted — it is a gesture, not user data.
    public internal(set) var spaceSwipeProgress: Double = 0

    /// A tab dropped into this window from a Space other than the one it is
    /// showing, awaiting confirmation. Non-nil puts the dialog on screen.
    public var pendingTabMove: PendingTabMove?

    // MARK: - MRU tab switching (Ctrl+Tab)

    /// The active Space's tabs in most-recently-used order, cached while an
    /// Arc-style Ctrl+Tab session is on screen so stepping is stable — the
    /// store rebuilds it when Ctrl goes down and nothing moves until release.
    /// Ephemeral and never persisted.
    public internal(set) var mruTabIDs: [UUID] = []

    /// The row the overlay is aiming at. `nil` until the first Tab press, so a
    /// quick Ctrl+Tab tap commits the most-recent tab and a bare Ctrl tap —
    /// pressed and released with no Tab — commits nothing.
    public internal(set) var mruCursor: Int?

    /// Whether the MRU switcher overlay is on screen. Set by the store as the
    /// Ctrl key goes down and up; the overlay is purely presentational.
    public internal(set) var isMRUSessionPresented = false

    // MARK: - Find in page

    /// Find-in-page state (M6), per-window because the bar belongs to a window
    /// and searches whatever *that* window is showing.
    public var isFindBarVisible = false
    public var findText = ""
    /// `nil` until a non-empty query has been run, so an empty bar does not
    /// report "not found".
    public internal(set) var findFoundMatch: Bool?
    @ObservationIgnored var findTask: Task<Void, Never>?

    /// A new window opens looking like the last one you configured: the
    /// persisted values are app-wide defaults that each window seeds from and
    /// then owns. Windows have no durable identity to key on until layout
    /// persistence exists, and inheriting is what Arc appears to do.
    public init(
        defaults: any PreferenceStore = UserDefaults.standard, isPrivate: Bool = false
    ) {
        self.isPrivate = isPrivate
        self.defaults = defaults
        self.isSidebarCollapsed = Preferences.loadSidebarCollapsed(defaults)
        self.sidebarWidth = Preferences.loadSidebarWidth(defaults)
        self.collapsedPinnedSpaces = Preferences.loadCollapsedPinnedSpaces(defaults)
    }

    // MARK: - Pinned section

    /// Whether the given Space's Pinned-tabs section is collapsed in this window
    /// (non-spec: user-requested) — so a long list of Pinned tabs does not push
    /// the ephemeral tabs off-screen.
    ///
    /// Takes the Space rather than reading the active one because the active
    /// Space still lives on `TabStore`; when selection moves here this loses the
    /// parameter again.
    public func isPinnedSectionCollapsed(inSpace spaceID: UUID?) -> Bool {
        guard let spaceID else { return false }
        return collapsedPinnedSpaces.contains(spaceID)
    }

    /// Expands or collapses the given Space's Pinned-tabs section in this window.
    public func togglePinnedSectionCollapsed(inSpace spaceID: UUID?) {
        guard let spaceID else { return }
        if collapsedPinnedSpaces.contains(spaceID) {
            collapsedPinnedSpaces.remove(spaceID)
        } else {
            collapsedPinnedSpaces.insert(spaceID)
        }
    }
}
