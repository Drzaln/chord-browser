import BrowserCore
import Foundation

/// Fixture builder, so tests read as the thing they are asserting rather than a
/// wall of initialiser arguments.
public struct TabBuilder {
    private var url = URL(string: "https://example.com")!
    private var title = ""
    private var placement = TabPlacement.ephemeral(order: 0)
    private var lastAccessed = Date(timeIntervalSince1970: 1_700_000_000)
    private var favicon: Data?
    private var extraPanes: [Pane] = []
    private var spaceID = TabBuilder.defaultSpaceID

    /// Stable across builders so tabs land in the same Space unless a test says
    /// otherwise.
    public static let defaultSpaceID = UUID()

    public static func defaultSpace() -> Space {
        Space(id: defaultSpaceID, name: "Personal", sortIndex: 0)
    }

    public init() {}

    public func space(_ id: UUID) -> Self {
        var copy = self
        copy.spaceID = id
        return copy
    }

    public func url(_ value: String) -> Self {
        var copy = self
        copy.url = URL(string: value)!
        return copy
    }

    public func title(_ value: String) -> Self {
        var copy = self
        copy.title = value
        return copy
    }

    public func pinned(order: Int = 0, homeURL: String? = nil) -> Self {
        var copy = self
        let home = homeURL.flatMap { URL(string: $0) } ?? copy.url
        copy.placement = .pinned(order: order, homeURL: home)
        return copy
    }

    /// An Arc-style *Pinned* tab, homed at `homeURL` (defaulting to the tab's
    /// own URL).
    public func bookmarked(order: Int = 0, homeURL: String? = nil) -> Self {
        var copy = self
        let home = homeURL.flatMap { URL(string: $0) } ?? copy.url
        copy.placement = .bookmarked(order: order, homeURL: home)
        return copy
    }

    public func ephemeral(order: Int = 0) -> Self {
        var copy = self
        copy.placement = .ephemeral(order: order)
        return copy
    }

    public func lastAccessed(_ value: Date) -> Self {
        var copy = self
        copy.lastAccessed = value
        return copy
    }

    public func favicon(_ value: Data?) -> Self {
        var copy = self
        copy.favicon = value
        return copy
    }

    public func extraPane(url value: String, widthFraction: Double = 0.5) -> Self {
        var copy = self
        copy.extraPanes.append(
            Pane(url: URL(string: value)!, widthFraction: widthFraction)
        )
        return copy
    }

    public func build() -> Tab {
        let first = Pane(url: url, title: title, faviconData: favicon)
        return Tab(
            spaceID: spaceID,
            placement: placement,
            panes: [first] + extraPanes,
            focusedPaneID: first.id,
            lastAccessedAt: lastAccessed,
            createdAt: lastAccessed
        )
    }
}
