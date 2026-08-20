import Foundation

/// A User-Agent chosen for one domain, overriding the global setting (§9.6).
///
/// The spec asked for this from the start — "~2% of sites are Chrome-only
/// tested. Add a per-domain user-agent override map rather than a global spoof"
/// — and the global setting that shipped first is exactly the thing §9.6 warns
/// about: it fixes one site and breaks another. Google Meet is the worked
/// example, twice: it refuses to start a call under the Firefox UA.
public struct UserAgentOverride: Codable, Hashable, Sendable, Identifiable {
    /// The registrable domain or host this applies to, normalised — lowercased,
    /// no scheme, no path, no leading dot. Matching covers subdomains.
    public let domain: String
    public var preference: UserAgentPreference

    public var id: String { domain }

    public init(domain: String, preference: UserAgentPreference) {
        self.domain = domain
        self.preference = preference
    }
}

/// Which User-Agent a URL gets. Pure, so the matching rules are testable without
/// a web view — and they need testing, because a loose suffix match here is the
/// same class of mistake as a loose origin match in the vault.
public enum UserAgentRules {

    /// Cleans up what the user typed into something matchable: accepts
    /// `https://meet.google.com/abc`, `meet.google.com`, or `.google.com` and
    /// returns `meet.google.com` / `google.com`. Nil when there is nothing
    /// usable left, so the UI can refuse to add an empty rule.
    public static func normalise(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        // Drop a path, query, fragment, port, and any credentials.
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        for separator in ["?", "#"] where text.contains(separator) {
            text = String(text.split(separator: separator, maxSplits: 1)[0])
        }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        while text.hasPrefix(".") { text.removeFirst() }
        while text.hasSuffix(".") { text.removeLast() }
        // A rule has to look like a host: at least one dot, no spaces. Otherwise
        // "chrome" would silently become a rule that matches nothing.
        guard !text.isEmpty, text.contains("."), !text.contains(" ") else { return nil }
        return text
    }

    /// The override that applies to `host`, or nil.
    ///
    /// A rule covers its subdomains — `google.com` matches `meet.google.com` —
    /// because that is what makes the map usable at all. **The suffix must be
    /// preceded by a dot**: `google.com` must never match `evil-google.com` or
    /// `notgoogle.com`, which is the whole reason this is one tested function
    /// rather than a `hasSuffix` at a call site.
    ///
    /// The **most specific** rule wins, so `meet.google.com → Default` can
    /// carve an exception out of `google.com → Chrome`.
    public static func match(host: String, in overrides: [UserAgentOverride]) -> UserAgentOverride? {
        let host = host.lowercased()
        return
            overrides
            .filter { host == $0.domain || host.hasSuffix("." + $0.domain) }
            .max { $0.domain.count < $1.domain.count }
    }

    /// The User-Agent string for a URL: the most specific matching override,
    /// falling back to the global preference. Nil means "leave WebKit's own
    /// completed Safari UA alone".
    ///
    /// A per-domain `.default` therefore *turns off* a global spoof for that
    /// site, which is the case the feature exists for.
    public static func resolve(
        url: URL?, overrides: [UserAgentOverride], global: UserAgentPreference
    ) -> String? {
        guard let host = url?.host() else { return global.resolvedUserAgent }
        guard let override = match(host: host, in: overrides) else {
            return global.resolvedUserAgent
        }
        return override.preference.resolvedUserAgent
    }
}
