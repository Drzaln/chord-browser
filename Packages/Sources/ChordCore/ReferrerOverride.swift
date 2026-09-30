import Foundation

/// What referrer a navigation sends (non-spec: user-requested, the Arc-like
/// privacy feature). The policy is applied at navigation time through
/// `WKWebpagePreferences.overrideReferrer` (macOS 27) — no JavaScript, and it
/// reaches the main resource *and* every subresource of the frame.
public enum ReferrerPolicy: Codable, Hashable, Sendable {
    /// WebKit's own referrer — the page URL, subject to the site's own policy.
    case `default`
    /// Send no referrer at all (an empty `Referer`).
    case strip
    /// Send this fixed URL as the referrer.
    case custom(String)

    /// The label the settings picker shows. Kept beside the type so a new case
    /// cannot be added without the UI being forced to name it.
    public var displayName: String {
        switch self {
        case .default: "Default"
        case .strip: "Strip"
        case .custom: "Custom"
        }
    }

    /// The policies offered in a picker, in order. Custom is chosen separately
    /// (it needs a URL field), so it is not in this list.
    public static let presets: [ReferrerPolicy] = [.default, .strip]
}

/// A referrer policy chosen for one domain, overriding the global setting.
public struct ReferrerOverride: Codable, Hashable, Sendable, Identifiable {
    /// The registrable domain or host this applies to, normalised — lowercased,
    /// no scheme, no path, no leading dot. Matching covers subdomains.
    public let domain: String
    public var policy: ReferrerPolicy

    public var id: String { domain }

    public init(domain: String, policy: ReferrerPolicy) {
        self.domain = domain
        self.policy = policy
    }
}

/// Which referrer a URL sends. Pure, so the matching rules are tested with no web
/// view — and they need testing, because a loose suffix match here is the same
/// class of mistake as a loose origin match in the vault. Shares the matcher
/// with `UserAgentRules` through `DomainRules`.
public enum ReferrerRules {

    /// Cleans up what the user typed into something matchable. See
    /// `DomainRules.normalise`.
    public static func normalise(_ input: String) -> String? {
        DomainRules.normalise(input)
    }

    /// The override that applies to `host`, or nil. The most specific rule wins,
    /// so a per-domain `.default` can carve an exception out of a global strip.
    public static func match(host: String, in overrides: [ReferrerOverride]) -> ReferrerOverride? {
        DomainRules.mostSpecific(host: host, in: overrides) { $0.domain }
    }

    /// The `overrideReferrer` value a navigation should carry, or nil to leave
    /// WebKit's own referrer alone.
    ///
    /// The three-way return is deliberate and matches the API: `nil` means "no
    /// override" (`.default`), `""` means "send none" (`.strip`), and anything
    /// else is the custom URL. A per-domain rule beats the global policy for the
    /// sites it names, including a per-domain `.default` that turns a global
    /// strip back off.
    public static func resolve(
        url: URL?, overrides: [ReferrerOverride], global: ReferrerPolicy
    ) -> String? {
        let policy: ReferrerPolicy
        if let host = url?.host(), let override = match(host: host, in: overrides) {
            policy = override.policy
        } else {
            policy = global
        }
        switch policy {
        case .default: return nil
        case .strip: return ""
        case .custom(let value): return value
        }
    }
}
