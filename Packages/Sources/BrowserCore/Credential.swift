import Foundation

/// A saved login, minus the password (V1 of the vault — see
/// `docs/design/password-vault.md`).
///
/// This is the half that is safe to keep in `browser.sqlite`: which site, which
/// username, when it was last used. **The secret never appears here** — it lives
/// in the Keychain, reachable only through `BrowserSecrets`, joined to this by
/// `id`. Keeping the split at the type level is what stops a password ever
/// reaching a database backup, a `.recover` dump, or a log line.
public struct Credential: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The origin this may be filled into, already normalised (`https://example.com`).
    /// Matching is exact — see `CredentialOrigin`.
    public let origin: String
    /// The username as the user typed it. Displayed in the picker, and half of
    /// the Keychain item's identity.
    public var username: String
    public var createdAt: Date
    public var lastUsedAt: Date?
    /// The Space this credential was last used in, so the Work Space can offer
    /// the work account first without the vault being partitioned. Nil until it
    /// has been used somewhere.
    public var lastUsedSpaceID: UUID?

    public init(
        id: UUID = UUID(),
        origin: String,
        username: String,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        lastUsedSpaceID: UUID? = nil
    ) {
        self.id = id
        self.origin = origin
        self.username = username
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lastUsedSpaceID = lastUsedSpaceID
    }
}

/// Normalises and compares the origins a credential may be saved for and filled
/// into — the single most security-sensitive function in the vault.
///
/// The rule is **exact origin equality**: scheme, host, and port must all match.
/// No parent-domain matching (`evil.example.com` must never see a credential
/// saved for `example.com`), no scheme relaxation, no public-suffix cleverness.
/// Password managers that match loosely do it to be helpful and pay for it in
/// credential-theft reports; this project has no reason to take that trade.
///
/// Pure and in `BrowserCore` so the rule can be tested exhaustively with no
/// Keychain, no web view, and no browser (§3.5).
public enum CredentialOrigin {

    /// The canonical origin string for a page URL, or nil if the URL is not
    /// somewhere a credential may ever be stored or filled.
    ///
    /// Rejects, deliberately:
    /// - anything that is not `https` (plaintext HTTP is not a place for a saved
    ///   password, and `http://localhost` needs an explicit developer opt-in that
    ///   V1 does not have),
    /// - URLs with no host, including `file:`, `about:`, and `data:`.
    ///
    /// Normalises: lowercases scheme and host, drops the default port, drops
    /// path, query, fragment, and any embedded credentials.
    public static func canonical(for url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            scheme == "https",
            let host = components.host?.lowercased(),
            !host.isEmpty
        else { return nil }

        // A trailing dot is the same host to DNS ("example.com." == "example.com")
        // but a different string, which would silently create a second entry.
        let normalisedHost = host.hasSuffix(".") ? String(host.dropLast()) : host

        if let port = components.port, port != 443 {
            return "\(scheme)://\(normalisedHost):\(port)"
        }
        return "\(scheme)://\(normalisedHost)"
    }

    /// Whether a credential saved for `stored` may be offered on `candidate`.
    ///
    /// Both sides are canonicalised first, so this is safe to call with raw page
    /// URLs. Exact match only, by design.
    public static func matches(stored: String, candidate: URL) -> Bool {
        guard let canonicalCandidate = canonical(for: candidate) else { return false }
        return stored == canonicalCandidate
    }
}
