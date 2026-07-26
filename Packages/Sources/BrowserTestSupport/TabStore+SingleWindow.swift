import BrowserCore
import BrowserStore
import Foundation

/// The window-free conveniences a *headless test* is entitled to.
///
/// The shipping API takes the window explicitly, because in the real app there
/// is no such thing as "the" selected tab — there is one per window, and code
/// that forgets which it means is the bug this whole split exists to prevent.
///
/// A test that builds a bare `TabStore` genuinely has one window, so making
/// every assertion say `in: store.primaryWindow` would add noise without adding
/// meaning. These live here, in a target only the test targets link, so the
/// convenience cannot leak into `BrowserUI` or the app.
///
/// If you reach for one of these in shipping code, that is the signal you have
/// not decided which window you mean.
@MainActor
extension TabStore {

    // MARK: - Selection

    public var selectedTabID: UUID? {
        get { primaryWindow.selectedTabID }
        set { primaryWindow.selectedTabID = newValue }
    }

    public var activeSpaceID: UUID? { primaryWindow.activeSpaceID }

    public var selectedTab: Tab? { selectedTab(in: primaryWindow) }

    // MARK: - Derived collections

    public var activeSpace: Space? { activeSpace(in: primaryWindow) }
    public var visibleTabs: [Tab] { visibleTabs(in: primaryWindow) }
    public var pinnedTabs: [Tab] { pinnedTabs(in: primaryWindow) }
    public var bookmarkedTabs: [Tab] { bookmarkedTabs(in: primaryWindow) }
    public var unpinnedTabs: [Tab] { unpinnedTabs(in: primaryWindow) }
    public var activeSpaceFolders: [Folder] { folders(in: primaryWindow) }

    // MARK: - Find

    public var isFindBarVisible: Bool {
        get { primaryWindow.isFindBarVisible }
        set { primaryWindow.isFindBarVisible = newValue }
    }

    public var findText: String {
        get { primaryWindow.findText }
        set { primaryWindow.findText = newValue }
    }

    public var findFoundMatch: Bool? { primaryWindow.findFoundMatch }

    public var spaceSwipeProgress: Double { primaryWindow.spaceSwipeProgress }

    // MARK: - Commands

    public func newTab(url: URL? = nil) { newTab(url: url, in: primaryWindow) }
    public func select(_ tabID: UUID) { select(tabID, in: primaryWindow) }
    public func closeTab(_ tabID: UUID) { closeTab(tabID, in: primaryWindow) }
    public func selectSpace(_ spaceID: UUID) { selectSpace(spaceID, in: primaryWindow) }
    public func selectSpace(atIndex index: Int) { selectSpace(atIndex: index, in: primaryWindow) }
    @discardableResult
    public func addSpace(name: String? = nil) -> Space { addSpace(name: name, in: primaryWindow) }
    public func deleteSpace(_ spaceID: UUID) async { await deleteSpace(spaceID, in: primaryWindow) }
    public func moveTab(_ tabID: UUID, toSpace spaceID: UUID) {
        moveTab(tabID, toSpace: spaceID, in: primaryWindow)
    }

    public func navigate(to url: URL) { navigate(to: url, in: primaryWindow) }
    public func reload() { reload(in: primaryWindow) }
    public func goBack() { goBack(in: primaryWindow) }
    public func goForward() { goForward(in: primaryWindow) }
    public func stopLoading() { stopLoading(in: primaryWindow) }
    public func printSelectedPane() { printSelectedPane(in: primaryWindow) }

    public func selectNextTab() { selectNextTab(in: primaryWindow) }
    public func selectPreviousTab() { selectPreviousTab(in: primaryWindow) }
    public func reopenLastClosedTab() { reopenLastClosedTab(in: primaryWindow) }
    public func returnToPinnedHome(_ tabID: UUID) { returnToPinnedHome(tabID, in: primaryWindow) }

    public func splitSelectedTab(url: URL? = nil) { splitSelectedTab(url: url, in: primaryWindow) }
    public func split(_ tabID: UUID, byMoving sourceTabID: UUID) {
        split(tabID, byMoving: sourceTabID, in: primaryWindow)
    }
    public func closePane(_ paneID: UUID) { closePane(paneID, in: primaryWindow) }

    public func showFindBar() { showFindBar(in: primaryWindow) }
    public func hideFindBar() { hideFindBar(in: primaryWindow) }
    public func findNext() { findNext(in: primaryWindow) }
    public func findPrevious() { findPrevious(in: primaryWindow) }

    public func restoreArchived(_ archived: ArchivedTab) {
        restoreArchived(archived, in: primaryWindow)
    }
    public func activate(_ suggestion: Suggestion, destination: ActivationDestination = .newTab) {
        activate(suggestion, destination: destination, in: primaryWindow)
    }
    public func loadFullHistory(limit: Int = 5_000) async -> [HistoryEntry] {
        await loadFullHistory(limit: limit, in: primaryWindow)
    }
    public func clearActiveSpaceHistory() async { await clearActiveSpaceHistory(in: primaryWindow) }
    public func openHistoryEntry(_ url: URL) { openHistoryEntry(url, in: primaryWindow) }
    public func promoteLittleArc(_ pane: Pane) -> UUID? {
        promoteLittleArc(pane, in: primaryWindow)
    }

    // MARK: - Space swipe

    public func canSwipeSpace(direction: Int) -> Bool {
        canSwipeSpace(direction: direction, in: primaryWindow)
    }
    public func beginSpaceSwipe() { beginSpaceSwipe(in: primaryWindow) }
    public func updateSpaceSwipe(offset: Double) { updateSpaceSwipe(offset: offset, in: primaryWindow) }
    public func setSpaceSwipeProgress(_ value: Double) {
        setSpaceSwipeProgress(value, in: primaryWindow)
    }
    public func commitSpaceSwipe(direction: Int) {
        commitSpaceSwipe(direction: direction, in: primaryWindow)
    }
    public var swipeShouldCommit: Bool { swipeShouldCommit(in: primaryWindow) }
    public var swipeBlendedGradient: [ColorHex] { swipeBlendedGradient(in: primaryWindow) }
}
