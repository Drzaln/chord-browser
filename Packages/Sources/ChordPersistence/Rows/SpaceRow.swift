import ChordCore
import Foundation
import GRDB

struct SpaceRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "space"

    var id: String
    var name: String
    var iconSymbol: String
    /// Comma-separated hex stops. A child table for two or three colours would
    /// cost a join on every load to buy nothing.
    var gradient: String
    var dataStoreID: String
    var sortIndex: Int
    var isPrivate: Bool
}

enum SpaceMapping {

    static func row(for space: Space) -> SpaceRow {
        SpaceRow(
            id: space.id.uuidString,
            name: space.name,
            iconSymbol: space.iconSymbol,
            gradient: space.gradient.map(\.value).joined(separator: ","),
            dataStoreID: space.dataStoreID.uuidString,
            sortIndex: space.sortIndex,
            isPrivate: space.isPrivate
        )
    }

    /// Defensive, like every other decode here: an unusable Space is skipped and
    /// logged rather than thrown, so one bad row cannot cost a launch (3.7).
    static func model(from row: SpaceRow) -> Space? {
        guard let id = UUID(uuidString: row.id) else {
            Log.db.error("skipping space with unparseable id")
            return nil
        }
        guard let dataStoreID = UUID(uuidString: row.dataStoreID) else {
            // Without a data store id the Space cannot be isolated, and a Space
            // that silently shares cookies is worse than a missing one.
            Log.db.error("skipping space \(row.id): bad dataStoreID")
            return nil
        }

        let stops = row.gradient
            .split(separator: ",")
            .map { ColorHex(String($0).trimmingCharacters(in: .whitespaces)) }

        return Space(
            id: id,
            name: row.name,
            iconSymbol: row.iconSymbol,
            gradient: stops.isEmpty ? Space.defaultGradient : stops,
            dataStoreID: dataStoreID,
            sortIndex: row.sortIndex,
            isPrivate: row.isPrivate
        )
    }
}
