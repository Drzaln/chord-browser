import ChordCore
import Foundation
import GRDB

/// Reads Chromium's `Login Data` from a **copy**, never in place.
///
/// The browser is usually running, and the live file is locked, actively
/// written, and not ours. Every read therefore goes through a private temp
/// directory that is created `0700`, holds a `0600` copy of the database (plus
/// its `-wal`/`-shm`/`-journal` siblings), and is removed in a `defer` — on
/// success, on a thrown error, and after the SQLite connection closes. The
/// caller's original path is opened only for the copy.
///
/// Read-only *at the source* is a guarantee made here, structurally: there is no
/// API on this type that accepts a database path for anything except copying.
public struct ChromiumLoginDatabaseReader: Sendable {
    /// Where the disposable copy is made. Injected only by tests, which need to
    /// look at the directory afterwards to prove it was cleaned up.
    private let temporaryDirectory: URL?

    /// A `Login Data` file larger than this is refused rather than copied. Real
    /// profiles are megabytes; a file this large is not one, and copying it
    /// would be a denial of service on the user's disk.
    public static let maximumDatabaseBytes = 256 << 20

    public init(temporaryDirectory: URL? = nil) {
        self.temporaryDirectory = temporaryDirectory
    }

    public func rows(at source: URL) throws -> [ChromiumLoginRow] {
        let values: URLResourceValues
        do {
            values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw ChromiumLoginDatabaseError.notReadable
        }
        guard values.isRegularFile == true else {
            throw ChromiumLoginDatabaseError.notRegularFile
        }
        if let size = values.fileSize, size > Self.maximumDatabaseBytes {
            throw ChromiumLoginDatabaseError.tooLarge
        }

        let root = temporaryDirectory ?? FileManager.default.temporaryDirectory
        let folder = root.appendingPathComponent(
            "chord-password-import-\(UUID().uuidString)", isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ChromiumLoginDatabaseError.copyFailed
        }
        defer { try? FileManager.default.removeItem(at: folder) }

        let copy: URL
        do {
            copy = try Self.copyForReading(source, into: folder)
        } catch let error as ChromiumLoginDatabaseError {
            throw error
        } catch {
            throw ChromiumLoginDatabaseError.copyFailed
        }

        return try Self.readRows(from: copy)
    }

    // MARK: - The copy

    /// Copies the database and the SQLite sidecars that may hold committed rows
    /// not yet checkpointed. Internal so a test can inspect the permissions of a
    /// live copy before the directory is removed.
    static func copyForReading(_ source: URL, into folder: URL) throws -> URL {
        let target = folder.appendingPathComponent("Login Data")
        do {
            try secureCopy(source, to: target)
            for suffix in ["-wal", "-shm", "-journal"] {
                try secureCopy(
                    URL(fileURLWithPath: source.path + suffix),
                    to: URL(fileURLWithPath: target.path + suffix),
                    optional: true
                )
            }
        } catch let error as ChromiumLoginDatabaseError {
            throw error
        } catch {
            throw ChromiumLoginDatabaseError.copyFailed
        }
        return target
    }

    /// `open` first, then copy from that descriptor, so a path swapped between
    /// the check and the copy cannot redirect the read. The destination is
    /// created `0600`; the temp directory around it is `0700`.
    private static func secureCopy(
        _ source: URL, to target: URL, optional: Bool = false
    ) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW)
        if input < 0 {
            if optional, errno == ENOENT { return }
            throw ChromiumLoginDatabaseError.notReadable
        }
        defer { close(input) }

        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ChromiumLoginDatabaseError.notRegularFile
        }
        guard info.st_size <= Self.maximumDatabaseBytes else {
            throw ChromiumLoginDatabaseError.tooLarge
        }

        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard output >= 0 else { throw ChromiumLoginDatabaseError.copyFailed }
        defer { close(output) }

        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            throw ChromiumLoginDatabaseError.copyFailed
        }
    }

    // MARK: - The read

    private static func readRows(from copy: URL) throws -> [ChromiumLoginRow] {
        do {
            let queue = try DatabaseQueue(path: copy.path)
            return try queue.read { db in
                guard try tableExists(db, named: "logins") else {
                    throw ChromiumLoginDatabaseError.schemaUnsupported
                }
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT signon_realm, origin_url, username_value,
                               password_value, blacklisted_by_user
                        FROM logins
                        """
                )
                return rows.enumerated().map { index, row in
                    ChromiumLoginRow(
                        rowIndex: index,
                        signonRealm: row["signon_realm"] as String? ?? "",
                        originURL: row["origin_url"] as String? ?? "",
                        username: row["username_value"] as String? ?? "",
                        ciphertext: (row["password_value"] as Data?) ?? Data(),
                        isBlacklisted: (row["blacklisted_by_user"] as Int? ?? 0) != 0
                    )
                }
            }
        } catch let error as ChromiumLoginDatabaseError {
            throw error
        } catch {
            throw ChromiumLoginDatabaseError.invalidDatabase
        }
    }

    private static func tableExists(_ db: Database, named name: String) throws -> Bool {
        let count =
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type = 'table' AND name = ?
                    """,
                arguments: [name]
            ) ?? 0
        return count > 0
    }
}
