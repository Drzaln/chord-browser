import Foundation
import GRDB

/// Owns the on-disk database and runs migrations at startup.
///
/// A `DatabaseQueue` serialises every write on its own background queue, so no
/// caller ever blocks the main thread on SQLite (6.5).
public struct BrowserDatabase: Sendable {
    public let writer: DatabaseQueue

    public static func open(at url: URL) throws -> BrowserDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }

        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw PersistenceError.openFailed(path: url.path, underlying: error)
        }

        let migrator = Migrations.makeMigrator()
        let needsMigration = try queue.read { db in
            try !migrator.hasCompletedMigrations(db)
        }
        if needsMigration {
            try Backup.snapshot(databaseAt: url)
        }

        do {
            try migrator.migrate(queue)
        } catch {
            throw PersistenceError.migrationFailed(
                name: "v\(Migrations.currentVersion)", underlying: error
            )
        }

        Log.db.info("database ready at schema v\(Migrations.currentVersion, privacy: .public)")
        return BrowserDatabase(writer: queue)
    }

    /// In-memory store for tests.
    public static func inMemory() throws -> BrowserDatabase {
        let queue = try DatabaseQueue()
        try Migrations.makeMigrator().migrate(queue)
        return BrowserDatabase(writer: queue)
    }
}

/// Pre-migration backups. Keeps the last three (7.2).
enum Backup {
    static let retained = 3

    static func snapshot(databaseAt url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }  // first launch

        let directory = url.deletingLastPathComponent().appending(path: "Backups")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = DateFormatter.backupStamp.string(from: Date())
        let destination = directory.appending(path: "\(url.lastPathComponent).\(stamp).bak")

        do {
            try fm.copyItem(at: url, to: destination)
        } catch {
            throw PersistenceError.backupFailed(underlying: error)
        }
        Log.db.notice("pre-migration backup written")

        prune(in: directory)
    }

    private static func prune(in directory: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }

        let stale = contents
            .filter { $0.pathExtension == "bak" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .dropFirst(retained)

        for file in stale {
            // Losing an old backup is not worth failing a launch over.
            try? fm.removeItem(at: file)
        }
    }
}

private extension DateFormatter {
    /// Lexicographically sortable, so pruning is a plain filename sort.
    static let backupStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
