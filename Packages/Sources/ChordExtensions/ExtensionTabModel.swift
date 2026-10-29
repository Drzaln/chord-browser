import Foundation

/// A tab as an extension needs to see it (7.3b). WebKit-free — this is the
/// vocabulary the `WKWebExtensionTab` adapters read, filled in by the Store.
public struct ExtensionTabSnapshot: Sendable, Equatable {
    public let id: UUID
    public let spaceID: UUID
    /// The pane whose `WKWebView` this tab shows. In a split, extensions see the
    /// focused pane — the one the user is reading (like find, §4.1).
    public let focusedPaneID: UUID
    public let url: URL?
    public let title: String
    public let isSelected: Bool
    /// Position within its Space, for `tabs.query({index})`.
    public let index: Int
    public let faviconData: Data?
    public let isPinned: Bool
    public let isAudible: Bool
    public let isMuted: Bool
    public let isLoading: Bool
    public let groupID: UUID?
    public let groupNumber: Int?
    public let isPrivate: Bool

    public init(
        id: UUID,
        spaceID: UUID,
        focusedPaneID: UUID,
        url: URL?,
        title: String,
        isSelected: Bool,
        index: Int,
        faviconData: Data? = nil,
        isPinned: Bool = false,
        isAudible: Bool = false,
        isMuted: Bool = false,
        isLoading: Bool = false,
        groupID: UUID? = nil,
        groupNumber: Int? = nil,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.spaceID = spaceID
        self.focusedPaneID = focusedPaneID
        self.url = url
        self.title = title
        self.isSelected = isSelected
        self.index = index
        self.faviconData = faviconData
        self.isPinned = isPinned
        self.isAudible = isAudible
        self.isMuted = isMuted
        self.isLoading = isLoading
        self.groupID = groupID
        self.groupNumber = groupNumber
        self.isPrivate = isPrivate
    }
}

/// What the extension tab/window adapters need from the app's tab state.
///
/// Defined here, in `ChordExtensions`, and implemented by `TabStore` up in
/// `ChordStore` — the "define the protocol in the lower target and inject"
/// rule (§3.5), because the adapters (WebKit) sit below the Store. WebKit-free
/// so the Store conforms without importing WebKit. Everything is Space-scoped:
/// extensions are per-Space (ADR 011), so a controller only ever sees its own
/// Space's tabs.
@MainActor
public protocol ExtensionTabModel: AnyObject {
    func extensionTabs(inSpace spaceID: UUID) -> [ExtensionTabSnapshot]
    func extensionActiveTab(inSpace spaceID: UUID) -> ExtensionTabSnapshot?
    func extensionTab(_ tabID: UUID) -> ExtensionTabSnapshot?

    /// The tab's focused pane, and nothing else. WebKit asks every tab for
    /// its web view on every network request of every page (to find the
    /// request's tab for webRequest), so this must stay cheap: no snapshot,
    /// no Space sort, no index.
    func extensionFocusedPaneID(_ tabID: UUID) -> UUID?

    /// Create a tab for `chrome.tabs.create`, in the Space's window. A nil
    /// result means the browser could not make one.
    func extensionCreateTab(
        url: URL, inSpace spaceID: UUID, active: Bool
    ) -> ExtensionTabSnapshot?

    func extensionActivateTab(_ tabID: UUID)
    func extensionLoadURL(_ url: URL, inTab tabID: UUID)
    func extensionReloadTab(_ tabID: UUID, fromOrigin: Bool)
    func extensionGoBack(inTab tabID: UUID)
    func extensionGoForward(inTab tabID: UUID)
    func extensionCloseTab(_ tabID: UUID)

    /// `chrome.tabs.move`: reorder within a Space, or move across Spaces.
    /// Optional for test doubles.
    func extensionMoveTab(_ tabID: UUID, to index: Int, inSpace spaceID: UUID)
    func extensionMoveTab(_ tabID: UUID, toSpace spaceID: UUID, at index: Int)
}

public extension ExtensionTabModel {
    func extensionMoveTab(_ tabID: UUID, to index: Int, inSpace spaceID: UUID) {}
    func extensionMoveTab(_ tabID: UUID, toSpace spaceID: UUID, at index: Int) {}
}

public extension ExtensionTabModel {
    /// Test doubles get it from their snapshot.
    func extensionFocusedPaneID(_ tabID: UUID) -> UUID? {
        extensionTab(tabID)?.focusedPaneID
    }
}

public extension ExtensionTabModel {
    /// Optional for test doubles and older conformers.
    func extensionCreateTab(
        url: URL, inSpace spaceID: UUID, active: Bool
    ) -> ExtensionTabSnapshot? { nil }
}
