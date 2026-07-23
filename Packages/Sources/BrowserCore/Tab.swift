import Foundation

/// A sidebar entry. Owns one or more panes; M1 only ever creates one.
///
/// `spaceID` is intentionally absent until M2 — see `docs/adr/003-no-space-in-m1.md`.
public struct Tab: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var placement: TabPlacement
    public var panes: [Pane]
    public var focusedPaneID: UUID
    public var lastAccessedAt: Date
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        placement: TabPlacement,
        panes: [Pane],
        focusedPaneID: UUID? = nil,
        lastAccessedAt: Date,
        createdAt: Date
    ) {
        precondition(!panes.isEmpty, "a tab must have at least one pane")
        self.id = id
        self.placement = placement
        self.panes = panes
        self.focusedPaneID = focusedPaneID ?? panes[0].id
        self.lastAccessedAt = lastAccessedAt
        self.createdAt = createdAt
    }

    /// Convenience for the M1 single-pane case.
    public init(url: URL, placement: TabPlacement, now: Date) {
        let pane = Pane(url: url)
        self.init(
            placement: placement,
            panes: [pane],
            focusedPaneID: pane.id,
            lastAccessedAt: now,
            createdAt: now
        )
    }

    public var focusedPane: Pane {
        panes.first { $0.id == focusedPaneID } ?? panes[0]
    }

    public func pane(_ id: UUID) -> Pane? {
        panes.first { $0.id == id }
    }

    public mutating func updatePane(_ id: UUID, _ mutate: (inout Pane) -> Void) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&panes[index])
    }

    public var displayTitle: String { focusedPane.displayTitle }
}
