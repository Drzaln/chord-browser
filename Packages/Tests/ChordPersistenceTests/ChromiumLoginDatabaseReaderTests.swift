import ChordCore
import Foundation
import GRDB
import Testing

@testable import ChordPersistence

/// The copy-then-read boundary. These tests care about three things the feature
/// promises: the original is untouched, the copy is private, and the copy is
/// gone afterwards even when the read fails.
@Suite("Chromium password database reader")
struct ChromiumPasswordDatabaseReaderTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chord-chromium-reader-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func makeLoginData(
        at url: URL, rows: [(realm: String, origin: String, user: String, blob: Data?, never: Bool)]
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE logins (
                        origin_url TEXT NOT NULL,
                        action_url TEXT,
                        username_element TEXT,
                        username_value TEXT,
                        password_element TEXT,
                        password_value BLOB,
                        submit_element TEXT,
                        signon_realm TEXT NOT NULL,
                        ssl_valid INTEGER NOT NULL DEFAULT 0,
                        preferred INTEGER NOT NULL DEFAULT 0,
                        date_created INTEGER NOT NULL DEFAULT 0,
                        blacklisted_by_user INTEGER NOT NULL DEFAULT 0,
                        scheme INTEGER NOT NULL DEFAULT 0
                    )
                    """
            )
            for row in rows {
                try db.execute(
                    sql: """
                        INSERT INTO logins (
                            origin_url, username_value, password_value,
                            signon_realm, blacklisted_by_user
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        row.origin, row.user, row.blob, row.realm, row.never ? 1 : 0,
                    ]
                )
            }
        }
    }

    @Test("Rows map to the values the importer needs")
    func mapsRows() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Google/Chrome/Default/Login Data")
        try makeLoginData(
            at: source,
            rows: [
                (
                    "https://example.com/", "https://example.com/login", "alice",
                    Data("v10abc".utf8), false,
                ),
                ("https://example.com/", "https://example.com/login", "bob", nil, true),
            ]
        )

        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )
        let rows = try ChromiumLoginDatabaseReader(temporaryDirectory: scratch)
            .rows(at: source)
        #expect(rows.count == 2)
        #expect(rows[0].rowIndex == 0)
        #expect(rows[0].signonRealm == "https://example.com/")
        #expect(rows[0].originURL == "https://example.com/login")
        #expect(rows[0].username == "alice")
        #expect(rows[0].ciphertext == Data("v10abc".utf8))
        #expect(!rows[0].isBlacklisted)
        #expect(rows[1].ciphertext.isEmpty)
        #expect(rows[1].isBlacklisted)
    }

    @Test("The source file is not modified and the temp copy is removed")
    func copyLifetimeOnSuccess() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Google/Chrome/Default/Login Data")
        try makeLoginData(
            at: source,
            rows: [("https://example.com/", "https://example.com/", "alice", Data([1]), false)]
        )
        let before = try FileManager.default.attributesOfItem(atPath: source.path)
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        _ = try ChromiumLoginDatabaseReader(temporaryDirectory: scratch).rows(at: source)

        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        #expect(
            (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date)
        )
        #expect((before[.size] as? NSNumber) == (after[.size] as? NSNumber))
    }

    @Test("A failed read still removes the copy")
    func copyLifetimeOnFailure() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Google/Chrome/Default/Login Data")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("this is not SQLite".utf8).write(to: source)
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let reader = ChromiumLoginDatabaseReader(temporaryDirectory: scratch)
        #expect(throws: ChromiumLoginDatabaseError.self) {
            _ = try reader.rows(at: source)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    @Test("The copy is 0600 inside a 0700 folder")
    func copyPermissions() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Google/Chrome/Default/Login Data")
        try makeLoginData(
            at: source,
            rows: [("https://example.com/", "https://example.com/", "alice", Data([1]), false)]
        )
        let folder = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let copy = try ChromiumLoginDatabaseReader.copyForReading(source, into: folder)
        let folderPermissions =
            (try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions]
                as? NSNumber)?.intValue
        let filePermissions =
            (try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions]
                as? NSNumber)?.intValue
        #expect(folderPermissions == 0o700)
        #expect(filePermissions == 0o600)
    }

    @Test("A SQLite file without the logins table is refused")
    func wrongSchema() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Google/Chrome/Default/Login Data")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: source.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE something_else (id INTEGER)")
        }
        // Close before reading so the connection cannot confuse the copy test.
        _ = queue

        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )
        #expect(throws: ChromiumLoginDatabaseError.schemaUnsupported) {
            _ = try ChromiumLoginDatabaseReader(temporaryDirectory: scratch)
                .rows(at: source)
        }
    }

    @Test("Rows committed to the WAL are read through the copy")
    func readsWAL() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Google/Chrome/Default/Login Data")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.journalMode = .wal
        let queue = try DatabaseQueue(path: source.path, configuration: configuration)
        try queue.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE logins (
                        origin_url TEXT NOT NULL, username_value TEXT,
                        password_value BLOB, signon_realm TEXT NOT NULL,
                        blacklisted_by_user INTEGER NOT NULL DEFAULT 0
                    )
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO logins (origin_url, username_value, password_value,
                        signon_realm, blacklisted_by_user)
                    VALUES ('https://wal.example/', 'alice', ?, 'https://wal.example/', 0)
                    """,
                arguments: [Data([0x76, 0x31, 0x30, 0x01])]
            )
        }
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let rows = try ChromiumLoginDatabaseReader(temporaryDirectory: scratch)
            .rows(at: source)
        #expect(rows.map(\.username) == ["alice"])
        #expect(rows.first?.signonRealm == "https://wal.example/")
        // Keep the connection alive until after the read: closing it may
        // checkpoint and would make this test pass for the wrong reason.
        withExtendedLifetime(queue) {}
    }
}
