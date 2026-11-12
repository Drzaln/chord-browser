import Foundation

/// A Chromium-family browser whose `Login Data` Chord can read.
///
/// Every browser in this family keeps saved passwords the same way: a SQLite
/// file called `Login Data` in each profile, and one Keychain generic-password
/// item named `"<Browser> Safe Storage"` that holds the passphrase for that
/// installation. The table is data, not policy: adding a browser is one entry,
/// and an unknown path is refused rather than guessed at, because guessing the
/// Keychain service means reading a key that may belong to something else.
public struct ChromiumBrowser: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    /// The Keychain service Chromium stores its encryption passphrase under.
    public let keychainService: String
    /// The Keychain account paired with the service. Chromium always sets one;
    /// matching both is what keeps a look-alike item from being accepted.
    public let keychainAccount: String
    /// Path components ending at the browser's user-data directory, e.g.
    /// `["Google", "Chrome"]`. Matched as a contiguous run anywhere in the
    /// picked path, so a profile copied out of Application Support still works.
    public let dataPath: [String]
    /// Opera keeps `Login Data` directly in its user-data folder instead of a
    /// `Default`/`Profile 1` folder inside it.
    public let keepsProfileInDataFolder: Bool

    public init(
        id: String,
        displayName: String,
        keychainService: String,
        keychainAccount: String,
        dataPath: [String],
        keepsProfileInDataFolder: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.dataPath = dataPath
        self.keepsProfileInDataFolder = keepsProfileInDataFolder
    }

    /// Chromium-family browsers that keep passwords in the documented format.
    /// Chrome's Beta/Dev/Canary builds share Chrome's Keychain item, so one
    /// approval covers all of them; the rest have their own.
    public static let known: [ChromiumBrowser] = [
        ChromiumBrowser(
            id: "dia", displayName: "Dia", keychainService: "Dia Safe Storage",
            keychainAccount: "Dia", dataPath: ["Dia", "User Data"]
        ),
        ChromiumBrowser(
            id: "chrome", displayName: "Google Chrome",
            keychainService: "Chrome Safe Storage", keychainAccount: "Chrome",
            dataPath: ["Google", "Chrome"]
        ),
        ChromiumBrowser(
            id: "chrome-beta", displayName: "Google Chrome Beta",
            keychainService: "Chrome Safe Storage", keychainAccount: "Chrome",
            dataPath: ["Google", "Chrome Beta"]
        ),
        ChromiumBrowser(
            id: "chrome-dev", displayName: "Google Chrome Dev",
            keychainService: "Chrome Safe Storage", keychainAccount: "Chrome",
            dataPath: ["Google", "Chrome Dev"]
        ),
        ChromiumBrowser(
            id: "chrome-canary", displayName: "Google Chrome Canary",
            keychainService: "Chrome Safe Storage", keychainAccount: "Chrome",
            dataPath: ["Google", "Chrome Canary"]
        ),
        ChromiumBrowser(
            id: "arc", displayName: "Arc", keychainService: "Arc Safe Storage",
            keychainAccount: "Arc", dataPath: ["Arc", "User Data"]
        ),
        ChromiumBrowser(
            id: "brave", displayName: "Brave", keychainService: "Brave Safe Storage",
            keychainAccount: "Brave", dataPath: ["BraveSoftware", "Brave-Browser"]
        ),
        ChromiumBrowser(
            id: "edge", displayName: "Microsoft Edge",
            keychainService: "Microsoft Edge Safe Storage",
            keychainAccount: "Microsoft Edge", dataPath: ["Microsoft Edge"]
        ),
        ChromiumBrowser(
            id: "vivaldi", displayName: "Vivaldi",
            keychainService: "Vivaldi Safe Storage", keychainAccount: "Vivaldi",
            dataPath: ["Vivaldi"]
        ),
        ChromiumBrowser(
            id: "chromium", displayName: "Chromium",
            keychainService: "Chromium Safe Storage", keychainAccount: "Chromium",
            dataPath: ["Chromium"]
        ),
        ChromiumBrowser(
            id: "opera", displayName: "Opera", keychainService: "Opera Safe Storage",
            keychainAccount: "Opera", dataPath: ["com.operasoftware.Opera"],
            keepsProfileInDataFolder: true
        ),
        ChromiumBrowser(
            id: "opera-gx", displayName: "Opera GX",
            keychainService: "Opera Safe Storage", keychainAccount: "Opera",
            dataPath: ["com.operasoftware.OperaGX"], keepsProfileInDataFolder: true
        ),
        ChromiumBrowser(
            id: "helium", displayName: "Helium", keychainService: "Helium Storage Key",
            keychainAccount: "Helium", dataPath: ["net.imput.helium"]
        ),
        ChromiumBrowser(
            id: "comet", displayName: "Comet", keychainService: "Comet Safe Storage",
            keychainAccount: "Comet", dataPath: ["Comet"]
        ),
    ]

    /// Works out which browser and profile a picked `Login Data` file belongs
    /// to, or nil when the path is not one of the known layouts.
    ///
    /// Refusing an unknown path is deliberate. The Keychain service name is a
    /// claim about which application wrote the ciphertext; deriving one from a
    /// folder name would turn a typo into a request for some other app's key.
    public static func detect(loginDataAt url: URL) -> ChromiumPasswordSource? {
        guard url.lastPathComponent == "Login Data" else { return nil }
        let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents

        for browser in known {
            guard let start = firstIndex(of: browser.dataPath, in: components) else {
                continue
            }
            let afterData = start + browser.dataPath.count
            if browser.keepsProfileInDataFolder {
                guard afterData < components.count,
                    components[afterData] == "Login Data"
                else { continue }
                return ChromiumPasswordSource(
                    browser: browser, profileName: browser.displayName, databaseURL: url
                )
            }
            guard afterData + 1 < components.count,
                components[afterData + 1] == "Login Data"
            else { continue }
            return ChromiumPasswordSource(
                browser: browser, profileName: components[afterData], databaseURL: url
            )
        }
        return nil
    }

    private static func firstIndex(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return start
            }
        }
        return nil
    }
}

/// A `Login Data` file that has been identified as belonging to one browser
/// profile. The URL is the user's original file; it is only ever copied.
public struct ChromiumPasswordSource: Sendable, Equatable {
    public let browser: ChromiumBrowser
    /// The profile folder's name (`Default`, `Profile 1`), or the browser's
    /// name for the browsers that keep a single profile at the root.
    public let profileName: String
    public let databaseURL: URL

    public init(browser: ChromiumBrowser, profileName: String, databaseURL: URL) {
        self.browser = browser
        self.profileName = profileName
        self.databaseURL = databaseURL
    }

    /// Builds a source for a file the user picked outside a known browser
    /// layout, after the UI asked which browser wrote it. The path still has to
    /// be a file named `Login Data`; nothing else is inferred from the folder.
    public init?(loginDataAt url: URL, browser: ChromiumBrowser) {
        guard url.lastPathComponent == "Login Data" else { return nil }
        let profile = url.deletingLastPathComponent().lastPathComponent
        guard !profile.isEmpty else { return nil }
        self.init(browser: browser, profileName: profile, databaseURL: url)
    }
}

/// One row of Chromium's `logins` table, as read from a temp copy.
///
/// `ciphertext` is the raw `password_value` blob — still encrypted. It is
/// carried around but never interpreted outside `ChordSecrets`, and it never
/// reaches the UI.
public struct ChromiumLoginRow: Sendable, Equatable {
    /// Position in the read result, used to name a failure without naming the
    /// account it belongs to.
    public let rowIndex: Int
    /// Chromium's canonical origin for the credential, e.g. `https://example.com/`.
    public let signonRealm: String
    /// The page the login was saved on (may include a path).
    public let originURL: String
    public let username: String
    public let ciphertext: Data
    /// Chromium's "never save for this site" marker. No secret is present and
    /// nothing should be imported.
    public let isBlacklisted: Bool

    public init(
        rowIndex: Int,
        signonRealm: String,
        originURL: String,
        username: String,
        ciphertext: Data,
        isBlacklisted: Bool = false
    ) {
        self.rowIndex = rowIndex
        self.signonRealm = signonRealm
        self.originURL = originURL
        self.username = username
        self.ciphertext = ciphertext
        self.isBlacklisted = isBlacklisted
    }
}

/// Why a row in another browser's database is not going to become a Chord
/// credential. Labels are shown in the dry run, so each says what happened
/// without naming a password.
public enum ChromiumPasswordSkipReason: String, Sendable, Equatable, CaseIterable,
    Hashable
{
    case blacklisted
    case emptyUsername
    case unsupportedScheme
    case insecureOrigin
    case embeddedCredentials
    case invalidOrigin
    case duplicateLogin
    case alreadyPresent

    public var label: String {
        switch self {
        case .blacklisted: "the site was marked “never save”"
        case .emptyUsername: "no username"
        case .unsupportedScheme: "not an http(s) site"
        case .insecureOrigin: "plain HTTP (Chord only fills HTTPS)"
        case .embeddedCredentials: "the address embeds a username or password"
        case .invalidOrigin: "the address has no usable host"
        case .duplicateLogin: "duplicate of an earlier row"
        case .alreadyPresent: "already saved in Chord"
        }
    }
}

/// A row that survived origin hygiene and is not already in the vault.
///
/// This is still ciphertext. The plaintext password exists only during the
/// import's write call, never in a plan, a preview, or the UI.
public struct ChromiumPasswordCandidate: Sendable, Equatable {
    public let rowIndex: Int
    public let origin: String
    public let username: String
    /// Empty when Chromium recorded the username without a password.
    public let ciphertext: Data
    /// Needed to verify Chromium's optional origin binding at decrypt time.
    public let signonRealm: String

    public init(
        rowIndex: Int, origin: String, username: String, ciphertext: Data,
        signonRealm: String
    ) {
        self.rowIndex = rowIndex
        self.origin = origin
        self.username = username
        self.ciphertext = ciphertext
        self.signonRealm = signonRealm
    }
}

/// A row that will not be imported, with the reason and its position in the
/// source table so the dry run can account for every row.
public struct ChromiumPasswordSkip: Sendable, Equatable {
    public let rowIndex: Int
    public let reason: ChromiumPasswordSkipReason

    public init(rowIndex: Int, reason: ChromiumPasswordSkipReason) {
        self.rowIndex = rowIndex
        self.reason = reason
    }
}

/// The result of applying Chord's storage rules to another browser's rows.
/// Pure: no file, Keychain, database, or network access.
public struct ChromiumPasswordPlan: Sendable, Equatable {
    public let source: ChromiumPasswordSource
    public let candidates: [ChromiumPasswordCandidate]
    public let skipped: [ChromiumPasswordSkip]

    public init(
        source: ChromiumPasswordSource,
        candidates: [ChromiumPasswordCandidate],
        skipped: [ChromiumPasswordSkip]
    ) {
        self.source = source
        self.candidates = candidates
        self.skipped = skipped
    }

    /// Rows that would be written, including username-only ones.
    public var importCount: Int { candidates.count }

    /// Rows already represented in the vault. Counted apart from skipped rows
    /// because "you already have this" is not a refusal.
    public var alreadyPresentCount: Int {
        skipped.count { $0.reason == .alreadyPresent }
    }

    /// Rows refused for every reason except already-present.
    public var skippedCount: Int { skipped.count - alreadyPresentCount }

    public func count(for reason: ChromiumPasswordSkipReason) -> Int {
        skipped.count { $0.reason == reason }
    }
}

/// The origin identity the vault joins on. Kept in Core so the importer can be
/// tested against a plan with no database behind it.
public struct ChromiumPasswordIdentity: Hashable, Sendable {
    public let origin: String
    public let username: String

    public init(origin: String, username: String) {
        self.origin = origin
        self.username = username
    }
}

/// The origin decision for one row: a canonical origin, or the reason it was
/// refused.
enum ChromiumOriginDecision: Equatable {
    case origin(String)
    case skipped(ChromiumPasswordSkipReason)
}

/// Turns another browser's rows into a Chord plan, applying **the vault's own
/// origin rules** and never adding a second matching rule.
///
/// Deliberate refusals:
/// - anything that is not `http`/`https` (`file:`, `javascript:`,
///   `chrome-extension:`, Android/Federation realms),
/// - plain `http`, because `CredentialOrigin.strict` will never fill it and a
///   stored credential that can never be used is a liability, not a feature,
/// - an address that embeds credentials (`https://user:pass@host/`),
/// - a host the canonicaliser rejects,
/// - an empty username, and Chromium's blacklist rows,
/// - a second row for the same `(origin, username)`,
/// - a login Chord already has, so an import never silently overwrites a newer
///   password.
public enum ChromiumPasswordPlanner {

    public static func plan(
        source: ChromiumPasswordSource,
        rows: [ChromiumLoginRow],
        existing: Set<ChromiumPasswordIdentity> = []
    ) -> ChromiumPasswordPlan {
        var candidates: [ChromiumPasswordCandidate] = []
        var skipped: [ChromiumPasswordSkip] = []
        var seen: Set<ChromiumPasswordIdentity> = []

        for row in rows {
            if row.isBlacklisted {
                skipped.append(.init(rowIndex: row.rowIndex, reason: .blacklisted))
                continue
            }
            guard !row.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                skipped.append(.init(rowIndex: row.rowIndex, reason: .emptyUsername))
                continue
            }
            let origin: String
            switch canonicalOrigin(signonRealm: row.signonRealm, originURL: row.originURL)
            {
            case .origin(let value): origin = value
            case .skipped(let reason):
                skipped.append(.init(rowIndex: row.rowIndex, reason: reason))
                continue
            }

            let identity = ChromiumPasswordIdentity(
                origin: origin, username: row.username
            )
            guard seen.insert(identity).inserted else {
                skipped.append(.init(rowIndex: row.rowIndex, reason: .duplicateLogin))
                continue
            }
            guard !existing.contains(identity) else {
                skipped.append(.init(rowIndex: row.rowIndex, reason: .alreadyPresent))
                continue
            }

            candidates.append(
                ChromiumPasswordCandidate(
                    rowIndex: row.rowIndex, origin: origin, username: row.username,
                    ciphertext: row.ciphertext, signonRealm: row.signonRealm
                )
            )
        }

        return ChromiumPasswordPlan(
            source: source, candidates: candidates, skipped: skipped
        )
    }

    /// The canonical origin for a Chromium realm, or why it is refused.
    ///
    /// The realm is preferred over `origin_url` because it is the value Chromium
    /// itself matches on. A missing realm falls back to the page URL; a realm
    /// that is present but unusable is refused rather than silently replaced.
    static func canonicalOrigin(
        signonRealm: String, originURL: String
    ) -> ChromiumOriginDecision {
        let raw = signonRealm.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = originURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text = raw.isEmpty ? (fallback.isEmpty ? nil : fallback) : raw,
            let components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased()
        else { return .skipped(.invalidOrigin) }

        guard scheme == "http" || scheme == "https" else {
            return .skipped(.unsupportedScheme)
        }
        // Userinfo in the *address* is the "IP with credentials" case and any
        // other `user:pass@host` form: the host would canonicalise cleanly and
        // quietly drop the credentials, which is exactly the sort of silent
        // rewrite an import must not do.
        guard components.user == nil, components.password == nil,
            !text.contains("@")
        else { return .skipped(.embeddedCredentials) }
        guard let url = components.url else { return .skipped(.invalidOrigin) }

        // The vault's rule, not a copy of it. `.strict` is HTTPS-only.
        guard let canonical = CredentialOrigin.canonical(for: url, policy: .strict)
        else {
            return .skipped(scheme == "http" ? .insecureOrigin : .invalidOrigin)
        }
        return .origin(canonical)
    }
}

/// Decrypts one Chromium `password_value`.
///
/// Declared in Core, implemented in `ChordSecrets`, so the Store can orchestrate
/// an import without holding key material or naming CommonCrypto. `invalidate()`
/// drops the derived key; the UI calls it on cancel and the importer on
/// completion.
public protocol ChromiumPasswordDecrypting: Sendable {
    func decrypt(_ ciphertext: Data, signonRealm: String) throws
        -> String
    func invalidate()
}

extension ChromiumPasswordDecrypting {
    public func invalidate() {}
}

/// Supplies a decryptor for one browser, normally by asking the macOS Keychain
/// for that browser's Safe Storage passphrase. A protocol so tests never need a
/// real Chrome profile or a Keychain prompt.
public protocol ChromiumPasswordKeyProviding: Sendable {
    func makeDecryptor(for browser: ChromiumBrowser) throws
        -> any ChromiumPasswordDecrypting
}

/// Why a `password_value` blob did not yield a password. None of these cases
/// carries plaintext, a key, or a ciphertext length.
public enum ChromiumPasswordDecryptionError: Error, Equatable, Hashable, Sendable {
    case malformedCiphertext
    case unrecognisedCiphertext
    /// A recognised but unsupported wrapper, e.g. `v20` app-bound encryption.
    /// The associated value is the version marker only.
    case unsupportedVersion(String)
    case decryptionFailed
    case invalidPlaintext
    /// The plaintext carried Chromium's 32-byte origin-binding prefix, and the
    /// prefix does not hash the row's realm.
    case originBindingMismatch

    public var explanation: String {
        switch self {
        case .malformedCiphertext:
            "the encrypted value is not a complete AES block"
        case .unrecognisedCiphertext:
            "the encrypted value has no Chromium version marker"
        case .unsupportedVersion(let version):
            if version == "v20" || version == "v21" {
                "the value uses \(version) app-bound encryption, which Chord "
                    + "cannot read"
            } else if version == "v12" {
                "the value uses \(version), a Linux portal key Chord cannot read"
            } else {
                "the value uses \(version), which Chord cannot read"
            }
        case .decryptionFailed:
            "the value did not decrypt with this browser's key"
        case .invalidPlaintext:
            "the decrypted value is not readable text"
        case .originBindingMismatch:
            "the value is encrypted for a different site"
        }
    }
}

/// What can go wrong while reading a Chromium database or its Keychain key.
/// These carry no secret and no row data; the importer attaches the row index
/// separately.
public enum ChromiumLoginDatabaseError: Error, Equatable, Sendable {
    case notReadable
    case notRegularFile
    case tooLarge
    case copyFailed
    case invalidDatabase
    case schemaUnsupported
}

/// What can go wrong reaching the browser's Safe Storage key.
public enum ChromiumSafeStorageKeyError: Error, Equatable, Sendable {
    /// No item with the expected service and account.
    case itemNotFound
    /// The Keychain refused. The raw `OSStatus` is the only diagnosable part.
    case keychain(status: Int32)
    /// The item's data was not UTF-8 text, so it is not the passphrase format
    /// Chromium writes.
    case notText
    case emptyKey
    /// Newer builds can store an encrypted wrapper instead of the passphrase.
    /// Refused with a clear message rather than guessed at: trying candidate
    /// interpretations until one decrypts is indistinguishable from brute force.
    case wrappedKeyUnsupported
    /// Anything the importer could not classify.
    case unreadable

    public var explanation: String {
        switch self {
        case .itemNotFound:
            "The browser's Safe Storage item is not in your Keychain. Open the "
                + "browser once and sign in, or choose a profile from a browser "
                + "that was actually used on this Mac."
        case .keychain(let status):
            "The Keychain refused the item (status \(status)). If a dialog "
                + "appeared, choose Always Allow and try again."
        case .notText:
            "The Safe Storage item does not contain the passphrase format "
                + "Chromium writes, so Chord cannot derive a key from it."
        case .emptyKey:
            "The Safe Storage item is empty, so there is no key to derive."
        case .wrappedKeyUnsupported:
            "This browser stores a wrapped encryption key. Chord does not guess "
                + "at unwrapping it, so nothing was imported. Import from an "
                + "older profile, or sign in to the sites in Chord and save the "
                + "logins again."
        case .unreadable:
            "Chord could not read the browser's Safe Storage key."
        }
    }
}
