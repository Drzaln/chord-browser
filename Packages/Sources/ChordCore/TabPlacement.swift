import Foundation

/// Where a tab sits in the sidebar, and whether the ephemeral sweep (M3) may
/// close it.
///
/// Three tiers, matching Arc's arrangement:
///   - `.pinned` — the **Favourites** icon grid at the top of the sidebar.
///     (The case is named `pinned` for historical reasons — it was the first
///     non-ephemeral tier and predates the section below.)
///   - `.bookmarked` — Arc's **Pinned** tabs: a list section between the
///     favourites grid and the loose tabs. Like a bookmark, it remembers the
///     URL it was pinned at (`homeURL`) and can be returned to it by clicking
///     the row.
///   - `.ephemeral` — a loose tab the sweep may auto-close once it goes idle.
public enum TabPlacement: Codable, Hashable, Sendable {
    /// A favourite — the icon grid at the top of the sidebar. Never auto-closed.
    /// `homeURL` is the URL it was pinned at, which double-clicking the tile
    /// returns it to; `nil` for favourites made before homes were recorded.
    case pinned(order: Int, homeURL: URL?)
    /// An Arc-style *Pinned* tab. Never auto-closed; `homeURL` is the URL it was
    /// pinned at, which clicking the row returns it to.
    case bookmarked(order: Int, homeURL: URL)
    /// Auto-closed after the idle window elapses.
    case ephemeral(order: Int)

    public var order: Int {
        switch self {
        case .pinned(let order, _), .bookmarked(let order, _), .ephemeral(let order): order
        }
    }

    /// Whether this is a favourite (the icon grid), *not* an Arc Pinned tab.
    public var isPinned: Bool {
        if case .pinned = self { return true }
        return false
    }

    /// Whether this is an Arc *Pinned* tab (the list section).
    public var isBookmarked: Bool {
        if case .bookmarked = self { return true }
        return false
    }

    /// Whether this is a loose, sweep-eligible tab.
    public var isEphemeral: Bool {
        if case .ephemeral = self { return true }
        return false
    }

    /// The URL a favourite or Pinned tab returns to; `nil` for a loose tab (or a
    /// favourite with no recorded home).
    public var homeURL: URL? {
        switch self {
        case .pinned(_, let homeURL): homeURL
        case .bookmarked(_, let homeURL): homeURL
        case .ephemeral: nil
        }
    }

    public func withOrder(_ order: Int) -> TabPlacement {
        switch self {
        case .pinned(_, let homeURL): .pinned(order: order, homeURL: homeURL)
        case .bookmarked(_, let homeURL): .bookmarked(order: order, homeURL: homeURL)
        case .ephemeral: .ephemeral(order: order)
        }
    }
}
