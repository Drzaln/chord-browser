import ChordCore
import ChordPersistence
import ChordSecrets
import Foundation

/// What the dry run says about a Chromium profile, before anything is written.
///
/// Contains no secrets — not even ciphertext. The decryptor that holds the
/// derived key is kept inside so the user is not asked for the Safe Storage key
/// twice; `invalidate()` drops it when the dialog closes.
public struct ChromiumPasswordImportPreview: Sendable {
    public let source: ChromiumPasswordSource
    /// One entry per source row, in row order. Skipped rows have empty origin
    /// and username: the reason and row index are the whole report.
    public let items: [ChromiumPasswordImportItem]
    public let withSecretCount: Int
    public let usernameOnlyCount: Int
    public let alreadyPresentCount: Int
    public let skippedCount: Int
    public let undecryptableCount: Int
    public let skippedByReason: [ChromiumPasswordSkipReason: Int]
    public let undecryptableByReason: [ChromiumPasswordDecryptionError: Int]

    let plan: ChromiumPasswordPlan
    let dispositions: [Int: ChromiumPasswordImportDisposition]
    let decryptor: (any ChromiumPasswordDecrypting)?

    public var importCount: Int { withSecretCount + usernameOnlyCount }
    public var hasAnythingToWrite: Bool { importCount > 0 }

    /// Drops the derived key. Called by the UI on cancel and by `apply` when it
    /// finishes; `deinit` of the decryptor covers an abandoned preview.
    public func invalidate() {
        decryptor?.invalidate()
    }
}

/// One row's outcome, without its secret or ciphertext.
public struct ChromiumPasswordImportItem: Sendable, Equatable, Identifiable {
    public let rowIndex: Int
    public let origin: String
    public let username: String
    public let disposition: ChromiumPasswordImportDisposition

    public var id: Int { rowIndex }

    public init(
        rowIndex: Int, origin: String, username: String,
        disposition: ChromiumPasswordImportDisposition
    ) {
        self.rowIndex = rowIndex
        self.origin = origin
        self.username = username
        self.disposition = disposition
    }
}

public enum ChromiumPasswordImportDisposition: Sendable, Equatable {
    /// A password is available and will be written to the Keychain.
    case importSecret
    /// Chromium had the username but no password; only metadata is written.
    case importUsernameOnly
    /// The vault already had this `(origin, username)`; nothing is overwritten.
    case alreadyPresent
    case skipped(ChromiumPasswordSkipReason)
    case undecryptable(ChromiumPasswordDecryptionError)
}

/// What one import wrote.
public struct ChromiumPasswordImportResult: Sendable, Equatable {
    public let importedWithSecret: Int
    public let importedUsernameOnly: Int
    public let alreadyPresent: Int
    public let skipped: Int
    public let undecryptable: Int
    /// Rows the plan wanted but a Keychain/glue write refused. Should be zero;
    /// reported rather than swallowed.
    public let failed: Int

    public var imported: Int { importedWithSecret + importedUsernameOnly }
}

public enum ChromiumPasswordImportError: Error, Equatable, Sendable {
    case unrecognisedBrowser
    case databaseUnreadable(ChromiumLoginDatabaseError)
    case noLogins
    case vaultUnavailable
    case privateWindow
    case keyUnavailable(ChromiumSafeStorageKeyError)

    public var title: String {
        switch self {
        case .unrecognisedBrowser: "Not a Chromium profile Chord can read"
        case .databaseUnreadable: "Could not read that Login Data file"
        case .noLogins: "No saved logins found"
        case .vaultUnavailable: "The password vault is not available"
        case .privateWindow: "Not available in a private window"
        case .keyUnavailable: "Could not read the browser's encryption key"
        }
    }

    public var message: String {
        switch self {
        case .unrecognisedBrowser:
            "Choose a file named “Login Data” inside a Chromium browser's "
                + "profile folder, for example Google/Chrome/Default/Login Data. "
                + "Nothing was imported."
        case .databaseUnreadable(let reason):
            switch reason {
            case .notReadable:
                "The file could not be opened. If it is in another browser's "
                    + "folder, choose it again and allow access. Nothing was imported."
            case .notRegularFile:
                "That is not a regular file. Choose the “Login Data” file itself. "
                    + "Nothing was imported."
            case .tooLarge:
                "The file is larger than any real Login Data database, so Chord "
                    + "refused to copy it. Nothing was imported."
            case .copyFailed:
                "Chord could not make a private copy of the database. Nothing was "
                    + "imported."
            case .invalidDatabase:
                "The copy is not a readable SQLite database. Nothing was imported."
            case .schemaUnsupported:
                "The file is SQLite, but it has no Chromium logins table. Nothing "
                    + "was imported."
            }
        case .noLogins:
            "The database is readable but holds no saved logins. Nothing was "
                + "imported."
        case .vaultUnavailable:
            "The vault could not be opened, so nothing was imported."
        case .privateWindow:
            "Private windows do not keep a Space, and imports write into the "
                + "profile. Open a normal window and try again."
        case .keyUnavailable(let reason):
            reason.explanation + " Nothing was imported."
        }
    }
}

/// Reads a Chromium `Login Data` file and writes what survives the vault's rules
/// through `CredentialVault` — the only path that touches the Keychain or the
/// credential table.
///
/// Two phases, deliberately:
/// 1. `preview` copies and reads the database, builds a plan, and decrypts each
///    candidate once **only to count it**. The plaintext is discarded there and
///    then; nothing secret survives into the preview.
/// 2. `apply` decrypts again and calls `CredentialVault.save` (or
///    `saveUsernameOnly`) per row. Cancel means `apply` is never called, so
///    cancel writes nothing by construction.
public struct ChromiumPasswordImporter: Sendable {
    private let vault: CredentialVault
    private let keyProvider: any ChromiumPasswordKeyProviding
    private let reader: ChromiumLoginDatabaseReader

    public init(
        vault: CredentialVault,
        keyProvider: any ChromiumPasswordKeyProviding = ChromiumSafeStorageKeychain(),
        reader: ChromiumLoginDatabaseReader = ChromiumLoginDatabaseReader()
    ) {
        self.vault = vault
        self.keyProvider = keyProvider
        self.reader = reader
    }

    public func preview(
        loginDataAt url: URL, browser: ChromiumBrowser? = nil
    ) async throws -> ChromiumPasswordImportPreview {
        let source =
            ChromiumBrowser.detect(loginDataAt: url)
            ?? browser.flatMap {
                ChromiumPasswordSource(loginDataAt: url, browser: $0)
            }
        guard let source else {
            throw ChromiumPasswordImportError.unrecognisedBrowser
        }

        let rows: [ChromiumLoginRow]
        do {
            rows = try reader.rows(at: url)
        } catch let error as ChromiumLoginDatabaseError {
            throw ChromiumPasswordImportError.databaseUnreadable(error)
        } catch {
            throw ChromiumPasswordImportError.databaseUnreadable(.invalidDatabase)
        }
        guard !rows.isEmpty else { throw ChromiumPasswordImportError.noLogins }

        let existing: [Credential]
        do {
            existing = try await vault.all()
        } catch {
            throw ChromiumPasswordImportError.vaultUnavailable
        }
        let known = Set(
            existing.map {
                ChromiumPasswordIdentity(origin: $0.origin, username: $0.username)
            }
        )
        let plan = ChromiumPasswordPlanner.plan(
            source: source, rows: rows, existing: known
        )

        // Only ask the Keychain when there is something to decrypt. A profile of
        // username-only rows should not produce an approval prompt.
        var decryptor: (any ChromiumPasswordDecrypting)?
        if plan.candidates.contains(where: { !$0.ciphertext.isEmpty }) {
            do {
                decryptor = try keyProvider.makeDecryptor(for: source.browser)
            } catch let error as ChromiumSafeStorageKeyError {
                throw ChromiumPasswordImportError.keyUnavailable(error)
            } catch {
                throw ChromiumPasswordImportError.keyUnavailable(.unreadable)
            }
        }

        var dispositions: [Int: ChromiumPasswordImportDisposition] = [:]
        for candidate in plan.candidates {
            if candidate.ciphertext.isEmpty {
                dispositions[candidate.rowIndex] = .importUsernameOnly
                continue
            }
            guard let decryptor else {
                dispositions[candidate.rowIndex] = .undecryptable(.decryptionFailed)
                continue
            }
            do {
                let secret = try decryptor.decrypt(
                    candidate.ciphertext, signonRealm: candidate.signonRealm
                )
                // Chromium never encrypts an empty password; a decrypted empty
                // string is a malformed row, not a credential.
                dispositions[candidate.rowIndex] =
                    secret.isEmpty ? .undecryptable(.invalidPlaintext) : .importSecret
            } catch let error as ChromiumPasswordDecryptionError {
                dispositions[candidate.rowIndex] = .undecryptable(error)
            } catch {
                dispositions[candidate.rowIndex] = .undecryptable(.decryptionFailed)
            }
        }

        var items: [ChromiumPasswordImportItem] = []
        items.reserveCapacity(rows.count)
        let candidates = Dictionary(
            uniqueKeysWithValues: plan.candidates.map { ($0.rowIndex, $0) }
        )
        let skips = Dictionary(
            uniqueKeysWithValues: plan.skipped.map { ($0.rowIndex, $0.reason) }
        )
        for row in rows {
            if let candidate = candidates[row.rowIndex] {
                items.append(
                    ChromiumPasswordImportItem(
                        rowIndex: row.rowIndex, origin: candidate.origin,
                        username: candidate.username,
                        disposition: dispositions[row.rowIndex]
                            ?? .undecryptable(.decryptionFailed)
                    )
                )
            } else if let reason = skips[row.rowIndex] {
                items.append(
                    ChromiumPasswordImportItem(
                        rowIndex: row.rowIndex, origin: "", username: "",
                        disposition: .skipped(reason)
                    )
                )
            }
        }

        let withSecret = dispositions.values.count { $0 == .importSecret }
        let usernameOnly = dispositions.values.count { $0 == .importUsernameOnly }
        var skippedByReason: [ChromiumPasswordSkipReason: Int] = [:]
        for skip in plan.skipped {
            skippedByReason[skip.reason, default: 0] += 1
        }
        var undecryptableByReason: [ChromiumPasswordDecryptionError: Int] = [:]
        for disposition in dispositions.values {
            if case .undecryptable(let reason) = disposition {
                undecryptableByReason[reason, default: 0] += 1
            }
        }

        return ChromiumPasswordImportPreview(
            source: source,
            items: items,
            withSecretCount: withSecret,
            usernameOnlyCount: usernameOnly,
            alreadyPresentCount: plan.alreadyPresentCount,
            skippedCount: plan.skippedCount,
            undecryptableCount: undecryptableByReason.values.reduce(0, +),
            skippedByReason: skippedByReason,
            undecryptableByReason: undecryptableByReason,
            plan: plan,
            dispositions: dispositions,
            decryptor: decryptor
        )
    }

    /// Writes the preview through the vault. Cancelling means never calling
    /// this; there is no write in `preview`.
    public func apply(
        _ preview: ChromiumPasswordImportPreview
    ) async -> ChromiumPasswordImportResult {
        defer { preview.invalidate() }

        let current: [Credential]
        do {
            current = try await vault.all()
        } catch {
            // Without a readable vault we cannot tell which logins already
            // exist, and `save` would upsert over one. Refuse the whole write
            // rather than risk overwriting a password.
            return ChromiumPasswordImportResult(
                importedWithSecret: 0,
                importedUsernameOnly: 0,
                alreadyPresent: preview.alreadyPresentCount,
                skipped: preview.skippedCount,
                undecryptable: preview.undecryptableCount,
                failed: preview.importCount
            )
        }
        var existing = Set(
            current.map {
                ChromiumPasswordIdentity(origin: $0.origin, username: $0.username)
            }
        )

        var withSecret = 0
        var usernameOnly = 0
        var alreadyPresent = preview.alreadyPresentCount
        var failed = 0

        for candidate in preview.plan.candidates {
            guard let disposition = preview.dispositions[candidate.rowIndex] else {
                continue
            }
            switch disposition {
            case .alreadyPresent, .skipped, .undecryptable:
                continue
            case .importSecret, .importUsernameOnly:
                break
            }

            let identity = ChromiumPasswordIdentity(
                origin: candidate.origin, username: candidate.username
            )
            // Re-checked here as well as at preview time: the vault may have
            // gained this login while the confirmation dialog was open, and an
            // import must not overwrite it.
            guard !existing.contains(identity) else {
                alreadyPresent += 1
                continue
            }

            do {
                if case .importUsernameOnly = disposition {
                    _ = try await vault.saveUsernameOnly(
                        origin: candidate.origin, username: candidate.username
                    )
                    usernameOnly += 1
                } else {
                    guard let decryptor = preview.decryptor else {
                        failed += 1
                        continue
                    }
                    let secret = try decryptor.decrypt(
                        candidate.ciphertext, signonRealm: candidate.signonRealm
                    )
                    guard !secret.isEmpty else {
                        failed += 1
                        continue
                    }
                    _ = try await vault.save(
                        origin: candidate.origin, username: candidate.username,
                        secret: secret
                    )
                    withSecret += 1
                }
                existing.insert(identity)
            } catch {
                // Never include the thrown error's payload: a Keychain error is
                // a status code, and this path must not accidentally print a
                // secret or a ciphertext.
                failed += 1
            }
        }

        return ChromiumPasswordImportResult(
            importedWithSecret: withSecret,
            importedUsernameOnly: usernameOnly,
            alreadyPresent: alreadyPresent,
            skipped: preview.skippedCount,
            undecryptable: preview.undecryptableCount,
            failed: failed
        )
    }
}
