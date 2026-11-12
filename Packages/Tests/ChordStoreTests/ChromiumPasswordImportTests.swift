import ChordCore
import ChordPersistence
import ChordSecrets
import CommonCrypto
import Foundation
import GRDB
import Testing

@testable import ChordSecrets
@testable import ChordStore

/// End-to-end Chromium import: a synthetic `Login Data` database, real Chord
/// vault metadata, and (for the round trip) the real Keychain secret store under
/// a throwaway service name.
@Suite("Chromium password import")
struct ChromiumPasswordImportTests {
    private let passphrase = "test-passphrase-899.15"
    /// Used only to encrypt rows that the browser key below must fail on.
    private let wrongPassphrase = "definitely-the-wrong-key"

    private struct SyntheticRow {
        let realm: String
        let origin: String
        let username: String
        let blob: Data
        var blacklisted = false
    }

    private struct FixedKeyProvider: ChromiumPasswordKeyProviding {
        let passphrase: String
        var failure: ChromiumSafeStorageKeyError?

        func makeDecryptor(
            for browser: ChromiumBrowser
        ) throws -> any ChromiumPasswordDecrypting {
            if let failure { throw failure }
            return try ChromiumPasswordDecryptor(passphrase: passphrase)
        }
    }

    private struct CryptoTestError: Error {}

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chord-chromium-import-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func makeLoginData(at url: URL, rows: [SyntheticRow]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE logins (
                        origin_url TEXT NOT NULL,
                        username_value TEXT,
                        password_value BLOB,
                        signon_realm TEXT NOT NULL,
                        blacklisted_by_user INTEGER NOT NULL DEFAULT 0
                    )
                    """
            )
            for row in rows {
                try db.execute(
                    sql: """
                        INSERT INTO logins (origin_url, username_value,
                            password_value, signon_realm, blacklisted_by_user)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        row.origin, row.username, row.blob, row.realm,
                        row.blacklisted ? 1 : 0,
                    ]
                )
            }
        }
    }

    private func makeVault() throws -> (CredentialVault, KeychainSecretStore) {
        let secrets = KeychainSecretStore(
            service: "com.rizal.chord.tests.password-import.\(UUID().uuidString)"
        )
        let vault = CredentialVault(
            repository: SQLiteCredentialRepository(database: try ChordDatabase.inMemory()),
            secrets: secrets
        )
        return (vault, secrets)
    }

    /// Chromium's writer, used only to build fixtures. The production recipe is
    /// pinned against externally produced vectors in
    /// `ChromiumPasswordDecryptorTests`.
    private func encrypt(_ plaintext: String, passphrase: String) throws -> Data {
        let key = ChromiumPasswordDecryptor.deriveKey(
            passphrase: Array(passphrase.utf8)
        )
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let input = Array(plaintext.utf8)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionPKCS7Padding),
            key,
            key.count,
            iv,
            input,
            input.count,
            &output,
            output.count,
            &moved
        )
        guard status == kCCSuccess else { throw CryptoTestError() }
        return Data("v10".utf8) + Data(output.prefix(moved))
    }

    private func scratchRoot(_ root: URL) throws -> URL {
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )
        return scratch
    }

    @Test("Dry run counts every row and writes nothing")
    func previewOnly() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Google/Chrome/Default/Login Data")
        let secret = "s3cr3t ✓ passphrase"
        let blob = try encrypt(secret, passphrase: passphrase)
        try makeLoginData(
            at: source,
            rows: [
                SyntheticRow(
                    realm: "https://example.com/", origin: "https://example.com/login",
                    username: "alice", blob: blob
                ),
                SyntheticRow(
                    realm: "https://username-only.example/",
                    origin: "https://username-only.example/login",
                    username: "bob", blob: Data()
                ),
                SyntheticRow(
                    realm: "https://example.com/", origin: "https://example.com/login",
                    username: "alice", blob: try encrypt("ignored", passphrase: passphrase)
                ),
                SyntheticRow(
                    realm: "file:///etc/passwd", origin: "file:///etc/passwd",
                    username: "carol", blob: blob
                ),
                SyntheticRow(
                    realm: "javascript:alert(1)", origin: "javascript:alert(1)",
                    username: "dave", blob: blob
                ),
                SyntheticRow(
                    realm: "https://malformed.example/",
                    origin: "https://malformed.example/",
                    username: "erin", blob: Data("v10abc".utf8)
                ),
                SyntheticRow(
                    realm: "https://wrong-key.example/",
                    origin: "https://wrong-key.example/",
                    username: "frank",
                    // Encrypted by a different passphrase for a fixed fixture, so
                    // this row is deterministically undecryptable rather than
                    // depending on PKCS#7 padding luck.
                    blob: try #require(
                        Data(
                            base64Encoded:
                                "djEwbLwBJT8fvsOGa4NVfmicEqMXWfs/gz9PutYkyNV0vk8="
                        )
                    )
                ),
                SyntheticRow(
                    realm: "http://plain.example/", origin: "http://plain.example/",
                    username: "grace", blob: blob
                ),
                SyntheticRow(
                    realm: "https://user:pw@embedded.example/",
                    origin: "https://user:pw@embedded.example/",
                    username: "heidi", blob: blob
                ),
                SyntheticRow(
                    realm: "https://no-user.example/", origin: "https://no-user.example/",
                    username: "   ", blob: blob
                ),
                SyntheticRow(
                    realm: "https://never.example/", origin: "https://never.example/",
                    username: "", blob: Data(), blacklisted: true
                ),
                SyntheticRow(
                    realm: "https://existing.example/",
                    origin: "https://existing.example/login", username: "me", blob: blob
                ),
            ]
        )

        let (vault, secrets) = try makeVault()
        _ = try await vault.save(
            origin: "https://existing.example", username: "me", secret: "old-secret"
        )
        defer {
            for id in (try? secrets.storedCredentialIDs()) ?? [] {
                try? secrets.delete(for: id)
            }
        }
        defer {
            for credential in (try? await vault.all()) ?? [] {
                try? await vault.delete(id: credential.id)
            }
        }

        let importer = ChromiumPasswordImporter(
            vault: vault,
            keyProvider: FixedKeyProvider(passphrase: passphrase),
            reader: ChromiumLoginDatabaseReader(temporaryDirectory: try scratchRoot(root))
        )
        let preview = try await importer.preview(loginDataAt: source)

        #expect(preview.source.browser.id == "chrome")
        #expect(preview.source.profileName == "Default")
        #expect(preview.items.count == 12)
        #expect(preview.withSecretCount == 1)
        #expect(preview.usernameOnlyCount == 1)
        #expect(preview.importCount == 2)
        #expect(preview.alreadyPresentCount == 1)
        #expect(preview.skippedCount == 7)
        #expect(preview.undecryptableCount == 2)
        #expect(preview.skippedByReason[.duplicateLogin] == 1)
        #expect(preview.skippedByReason[.unsupportedScheme] == 2)
        #expect(preview.skippedByReason[.insecureOrigin] == 1)
        #expect(preview.skippedByReason[.embeddedCredentials] == 1)
        #expect(preview.skippedByReason[.emptyUsername] == 1)
        #expect(preview.skippedByReason[.blacklisted] == 1)
        #expect(preview.skippedByReason[.alreadyPresent] == 1)
        #expect(preview.undecryptableByReason[.malformedCiphertext] == 1)
        let wrongKeyFailures =
            (preview.undecryptableByReason[.decryptionFailed] ?? 0)
            + (preview.undecryptableByReason[.invalidPlaintext] ?? 0)
        #expect(
            wrongKeyFailures == 1,
            "reasons: \(preview.undecryptableByReason)"
        )

        // The dry run is not a write.
        let beforeApply = try await vault.all()
        #expect(beforeApply.count == 1)
        #expect(try await vault.storedSecret(for: try #require(beforeApply.first).id) == "old-secret")
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: try scratchRoot(root).path
        ).isEmpty)

        // The preview contains no secret and no ciphertext.
        let rendered = "\(preview.items) \(preview.skippedByReason) "
            + "\(preview.undecryptableByReason) \(preview.withSecretCount)"
        #expect(!rendered.contains(secret))
        #expect(!rendered.contains(blob.base64EncodedString()))
        #expect(!rendered.contains(passphrase))

        let result = await importer.apply(preview)
        #expect(result.importedWithSecret == 1)
        #expect(result.importedUsernameOnly == 1)
        #expect(result.imported == 2)
        #expect(result.alreadyPresent == 1)
        #expect(result.skipped == 7)
        #expect(result.undecryptable == 2)
        #expect(result.failed == 0)

        let all = try await vault.all()
        #expect(all.count == 3)
        let imported = try #require(
            all.first {
                $0.origin == "https://example.com" && $0.username == "alice"
            }
        )
        #expect(try secrets.secret(for: imported.id) == secret)
        let usernameOnly = try #require(
            all.first {
                $0.origin == "https://username-only.example" && $0.username == "bob"
            }
        )
        #expect(try secrets.secret(for: usernameOnly.id) == nil)
        let existing = try #require(
            all.first {
                $0.origin == "https://existing.example" && $0.username == "me"
            }
        )
        #expect(try secrets.secret(for: existing.id) == "old-secret")

        #expect(all.contains { $0.origin == "file:///etc/passwd" } == false)
        #expect(all.contains { $0.origin == "http://plain.example" } == false)
        #expect(all.contains { $0.origin == "https://wrong-key.example" } == false)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: try scratchRoot(root).path
        ).isEmpty)

        for credential in all {
            try? await vault.delete(id: credential.id)
        }
        #expect(try secrets.storedCredentialIDs().isEmpty)
    }

    @Test("A wrong key imports nothing and says every row is undecryptable")
    func wrongKey() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Google/Chrome/Default/Login Data")
        let wrongKeyBlob = try #require(
            Data(
                base64Encoded: "djEwbLwBJT8fvsOGa4NVfmicEqMXWfs/gz9PutYkyNV0vk8="
            )
        )
        try makeLoginData(
            at: source,
            rows: [
                SyntheticRow(
                    realm: "https://one.example/", origin: "https://one.example/",
                    username: "a", blob: wrongKeyBlob
                ),
                SyntheticRow(
                    realm: "https://two.example/", origin: "https://two.example/",
                    username: "b", blob: wrongKeyBlob
                ),
            ]
        )
        let (vault, secrets) = try makeVault()
        let importer = ChromiumPasswordImporter(
            vault: vault,
            keyProvider: FixedKeyProvider(passphrase: passphrase),
            reader: ChromiumLoginDatabaseReader(temporaryDirectory: try scratchRoot(root))
        )

        let preview = try await importer.preview(loginDataAt: source)
        #expect(preview.importCount == 0)
        #expect(preview.undecryptableCount == 2)
        let wrongKeyFailures =
            (preview.undecryptableByReason[.decryptionFailed] ?? 0)
            + (preview.undecryptableByReason[.invalidPlaintext] ?? 0)
        #expect(
            wrongKeyFailures == 2,
            "reasons: \(preview.undecryptableByReason)"
        )

        let result = await importer.apply(preview)
        #expect(result.imported == 0)
        #expect(result.failed == 0)
        #expect(try await vault.all().isEmpty)
        #expect(try secrets.storedCredentialIDs().isEmpty)
    }

    @Test("An absent Safe Storage key is a clear error and writes nothing")
    func missingKey() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Google/Chrome/Default/Login Data")
        try makeLoginData(
            at: source,
            rows: [
                SyntheticRow(
                    realm: "https://example.com/", origin: "https://example.com/",
                    username: "alice",
                    blob: try encrypt("secret-value", passphrase: passphrase)
                )
            ]
        )
        let (vault, secrets) = try makeVault()
        let importer = ChromiumPasswordImporter(
            vault: vault,
            keyProvider: FixedKeyProvider(
                passphrase: passphrase, failure: .itemNotFound
            ),
            reader: ChromiumLoginDatabaseReader(temporaryDirectory: try scratchRoot(root))
        )

        do {
            _ = try await importer.preview(loginDataAt: source)
            Issue.record("the preview succeeded without a key")
        } catch let error as ChromiumPasswordImportError {
            #expect(error == .keyUnavailable(.itemNotFound))
            #expect(error.message.contains("Safe Storage"))
            #expect(!error.message.contains("secret-value"))
            #expect(!error.message.contains(passphrase))
        }
        #expect(try await vault.all().isEmpty)
        #expect(try secrets.storedCredentialIDs().isEmpty)
    }

    @Test("A wrapped Safe Storage key is reported, not guessed at")
    func wrappedKey() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Google/Chrome/Default/Login Data")
        try makeLoginData(
            at: source,
            rows: [
                SyntheticRow(
                    realm: "https://example.com/", origin: "https://example.com/",
                    username: "alice",
                    blob: try encrypt("secret-value", passphrase: passphrase)
                )
            ]
        )
        let (vault, _) = try makeVault()
        let importer = ChromiumPasswordImporter(
            vault: vault,
            keyProvider: FixedKeyProvider(
                passphrase: passphrase, failure: .wrappedKeyUnsupported
            ),
            reader: ChromiumLoginDatabaseReader(temporaryDirectory: try scratchRoot(root))
        )

        do {
            _ = try await importer.preview(loginDataAt: source)
            Issue.record("the preview accepted a wrapped key")
        } catch let error as ChromiumPasswordImportError {
            #expect(error == .keyUnavailable(.wrappedKeyUnsupported))
            #expect(error.message.contains("wrapped encryption key"))
            #expect(!error.message.contains("secret-value"))
        }
        #expect(try await vault.all().isEmpty)
    }

    @Test("A username-only profile never asks the Keychain")
    func usernameOnlyNeedsNoKey() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Deliberately not a standard browser path: this is the throwaway
        // `--user-data-dir=/tmp/...` profile from the smoke test, where the
        // browser can only be known because the UI asked.
        let source = root.appendingPathComponent("chord-passwords-smoke/Default/Login Data")
        try makeLoginData(
            at: source,
            rows: [
                SyntheticRow(
                    realm: "https://no-password.example/",
                    origin: "https://no-password.example/", username: "alice",
                    blob: Data()
                )
            ]
        )
        let chrome = try #require(ChromiumBrowser.known.first { $0.id == "chrome" })
        let (vault, secrets) = try makeVault()
        let importer = ChromiumPasswordImporter(
            vault: vault,
            keyProvider: FixedKeyProvider(
                passphrase: passphrase, failure: .itemNotFound
            ),
            reader: ChromiumLoginDatabaseReader(temporaryDirectory: try scratchRoot(root))
        )

        let preview = try await importer.preview(loginDataAt: source, browser: chrome)
        #expect(preview.source.browser.id == "chrome")
        #expect(preview.source.profileName == "Default")
        #expect(preview.withSecretCount == 0)
        #expect(preview.usernameOnlyCount == 1)
        let result = await importer.apply(preview)
        #expect(result.importedUsernameOnly == 1)
        let all = try await vault.all()
        #expect(all.count == 1)
        #expect(try secrets.secret(for: try #require(all.first).id) == nil)
        for credential in all {
            try? await vault.delete(id: credential.id)
        }
    }

    @Test("A failed preview leaves no temp copy behind")
    func tempLifetimeOnThrow() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Google/Chrome/Default/Login Data")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not a database".utf8).write(to: source)
        let (vault, _) = try makeVault()
        let scratch = try scratchRoot(root)
        let importer = ChromiumPasswordImporter(
            vault: vault, keyProvider: FixedKeyProvider(passphrase: passphrase),
            reader: ChromiumLoginDatabaseReader(temporaryDirectory: scratch)
        )

        do {
            _ = try await importer.preview(loginDataAt: source)
            Issue.record("a non-database preview succeeded")
        } catch let error as ChromiumPasswordImportError {
            #expect(error == .databaseUnreadable(.invalidDatabase))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    @Test("A row's failure text names no secret material")
    func redaction() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Google/Chrome/Default/Login Data")
        let secret = "do-not-print-this-password"
        let blob = try encrypt(secret, passphrase: wrongPassphrase)
        try makeLoginData(
            at: source,
            rows: [
                SyntheticRow(
                    realm: "https://redact.example/", origin: "https://redact.example/",
                    username: "alice", blob: blob
                )
            ]
        )
        let (vault, _) = try makeVault()
        let importer = ChromiumPasswordImporter(
            vault: vault, keyProvider: FixedKeyProvider(passphrase: passphrase),
            reader: ChromiumLoginDatabaseReader(temporaryDirectory: try scratchRoot(root))
        )
        let preview = try await importer.preview(loginDataAt: source)
        let rendered = "\(preview.items) \(preview.undecryptableByReason)"
        #expect(preview.undecryptableCount == 1)
        #expect(!rendered.contains(secret))
        #expect(!rendered.contains(blob.base64EncodedString()))
        #expect(!rendered.contains(passphrase))
    }
}
