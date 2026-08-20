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

    public init(
        id: UUID,
        spaceID: UUID,
        focusedPaneID: UUID,
        url: URL?,
        title: String,
        isSelected: Bool,
        index: Int
    ) {
        self.id = id
        self.spaceID = spaceID
        self.focusedPaneID = focusedPaneID
        self.url = url
        self.title = title
        self.isSelected = isSelected
        self.index = index
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

    func extensionActivateTab(_ tabID: UUID)
    func extensionLoadURL(_ url: URL, inTab tabID: UUID)
    func extensionReloadTab(_ tabID: UUID, fromOrigin: Bool)
    func extensionGoBack(inTab tabID: UUID)
    func extensionGoForward(inTab tabID: UUID)
    func extensionCloseTab(_ tabID: UUID)
}
