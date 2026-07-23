import Foundation

/// Where a tab sits in the sidebar, and whether the ephemeral sweep (M3) may
/// close it.
public enum TabPlacement: Codable, Hashable, Sendable {
    /// Never auto-closed.
    case pinned(order: Int)
    /// Auto-closed after the idle window elapses.
    case ephemeral(order: Int)

    public var order: Int {
        switch self {
        case .pinned(let order), .ephemeral(let order): order
        }
    }

    public var isPinned: Bool {
        if case .pinned = self { return true }
        return false
    }

    public func withOrder(_ order: Int) -> TabPlacement {
        switch self {
        case .pinned: .pinned(order: order)
        case .ephemeral: .ephemeral(order: order)
        }
    }
}
