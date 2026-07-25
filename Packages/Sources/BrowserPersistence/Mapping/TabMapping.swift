import BrowserCore
import Foundation

/// Row <-> model translation. The only place that knows both shapes.
///
/// Decoding is defensive by contract: a row that cannot be made into a valid
/// model returns nil and is skipped with a log, never thrown. A corrupt tab must
/// cost the user one tab, not a launch (3.7).
enum TabMapping {

    // MARK: - Model -> rows

    static func rows(for tab: Tab) -> (tab: TabRow, panes: [PaneRow]) {
        let kind: String
        switch tab.placement {
        case .pinned: kind = "pinned"
        case .ephemeral: kind = "ephemeral"
        }

        let tabRow = TabRow(
            id: tab.id.uuidString,
            spaceId: tab.spaceID.uuidString,
            placementKind: kind,
            placementOrder: tab.placement.order,
            folderId: tab.folderID?.uuidString,
            focusedPaneID: tab.focusedPaneID.uuidString,
            lastAccessedAt: tab.lastAccessedAt.timeIntervalSince1970,
            createdAt: tab.createdAt.timeIntervalSince1970
        )

        let paneRows = tab.panes.enumerated().map { position, pane in
            PaneRow(
                id: pane.id.uuidString,
                tabId: tab.id.uuidString,
                position: position,
                url: pane.url.absoluteString,
                title: pane.title,
                faviconData: pane.faviconData,
                widthFraction: pane.widthFraction
            )
        }

        return (tabRow, paneRows)
    }

    // MARK: - Rows -> model

    static func model(tabRow: TabRow, paneRows: [PaneRow]) -> Tab? {
        guard let id = UUID(uuidString: tabRow.id) else {
            Log.db.error("skipping tab with unparseable id")
            return nil
        }

        guard let spaceID = UUID(uuidString: tabRow.spaceId) else {
            // An unowned tab would be invisible in every Space, which reads to
            // the user as data loss. Better to skip it loudly.
            Log.db.error("skipping tab \(tabRow.id, privacy: .public): bad spaceId")
            return nil
        }

        let panes = paneRows
            .sorted { $0.position < $1.position }
            .compactMap(pane(from:))

        guard !panes.isEmpty else {
            Log.db.error("skipping tab \(tabRow.id, privacy: .public): no usable panes")
            return nil
        }

        guard let placement = placement(kind: tabRow.placementKind, order: tabRow.placementOrder)
        else {
            Log.db.error("skipping tab \(tabRow.id, privacy: .public): unknown placement kind")
            return nil
        }

        // A dangling focus pointer is recoverable — fall back to the first pane
        // rather than discarding the tab.
        let storedFocus = UUID(uuidString: tabRow.focusedPaneID)
        let focus = panes.contains { $0.id == storedFocus } ? storedFocus : panes[0].id

        // A folderId that is unparseable or points at a folder that no longer
        // exists is treated as "no folder" — the tab is never lost over it.
        let folderID = tabRow.folderId.flatMap(UUID.init(uuidString:))

        return Tab(
            id: id,
            spaceID: spaceID,
            placement: placement,
            folderID: folderID,
            panes: panes,
            focusedPaneID: focus,
            lastAccessedAt: Date(timeIntervalSince1970: tabRow.lastAccessedAt),
            createdAt: Date(timeIntervalSince1970: tabRow.createdAt)
        )
    }

    private static func pane(from row: PaneRow) -> Pane? {
        guard let id = UUID(uuidString: row.id), let url = URL(string: row.url) else {
            Log.db.error("skipping unparseable pane row")
            return nil
        }
        return Pane(
            id: id,
            url: url,
            title: row.title,
            faviconData: row.faviconData,
            interactionState: nil,  // loaded on demand
            widthFraction: row.widthFraction
        )
    }

    private static func placement(kind: String, order: Int) -> TabPlacement? {
        switch kind {
        case "pinned": .pinned(order: order)
        case "ephemeral": .ephemeral(order: order)
        default: nil
        }
    }
}
