import Foundation

/// Which kind of arriving URL a routing rule is being asked about.
///
/// The distinction exists because the two need different manners: a link from
/// another app was launched deliberately, so the user should end up looking at
/// it, while a ⌘-click inside a page is a "keep reading" gesture and must not
/// yank the window into another Space.
public enum RoutedOpenKind: String, Codable, Hashable, Sendable {
    /// A link handed to the app by macOS — another app, a Dock drop, a
    /// Spotlight result. Always routed when a rule matches.
    case external
    /// A new tab opened from inside a page: ⌘-click, middle-click, or a
    /// `target=_blank` link. Routed only when the rule asks for it, because
    /// plenty of people want a rule for externally-opened links only.
    case newTab
}

/// One "this site belongs in that Space" rule (non-spec: user-requested).
///
/// A rule is a *default*, never a hijack: an explicit Space choice, a split, a
/// Peek, or a private window all win. See `RouteRules` for the matching and
/// ADR 023 for why there is exactly one place that applies them.
public struct RouteRule: Codable, Hashable, Sendable, Identifiable {
    /// The registrable domain or host this applies to, normalised — lowercased,
    /// no scheme, no path, no leading dot. Covers subdomains.
    public let pattern: String
    /// The Space an arriving URL from this site belongs in.
    public var spaceID: UUID
    /// Whether a new tab opened from inside a page is routed too. External
    /// launches are always routed; this is the switch for ⌘-clicked links.
    public var routesNewTabs: Bool
    /// Off keeps the rule without deleting it — the Settings list has a toggle
    /// rather than making the user retype a host to pause one.
    public var isEnabled: Bool

    public var id: String { pattern }

    public init(
        pattern: String, spaceID: UUID, routesNewTabs: Bool = true, isEnabled: Bool = true
    ) {
        self.pattern = pattern
        self.spaceID = spaceID
        self.routesNewTabs = routesNewTabs
        self.isEnabled = isEnabled
    }
}

/// Matching for routing rules. Pure, so the precedence that matters — "which
/// Space does this link land in?" — is testable without a window or a web view.
///
/// Reuses `DomainRules` rather than growing a second suffix matcher: the
/// per-domain User-Agent and referrer maps already share it, and a loose match
/// here would send a link to the wrong Space, which is exactly as bad as
/// applying the wrong origin's password.
public enum RouteRules {

    /// Cleans up what the user typed into something matchable. Nil when there is
    /// nothing usable left, so the UI can refuse to store a rule that matches
    /// nothing.
    public static func normalise(_ input: String) -> String? {
        DomainRules.normalise(input)
    }

    /// The enabled rule that applies to `host`, most specific wins. A rule covers
    /// its subdomains, and the suffix must be preceded by a dot — see
    /// `DomainRules.mostSpecific`.
    public static func match(host: String, in rules: [RouteRule]) -> RouteRule? {
        DomainRules.mostSpecific(host: host, in: rules.filter(\.isEnabled)) { $0.pattern }
    }

    /// The Space a URL should land in, or nil when no rule applies.
    ///
    /// `knownSpaceIDs` is passed in rather than assumed: a rule whose Space has
    /// been deleted must be inert, not a destination that no longer exists.
    public static func destination(
        for url: URL,
        kind: RoutedOpenKind,
        rules: [RouteRule],
        knownSpaceIDs: Set<UUID>
    ) -> UUID? {
        guard let host = url.host(), !rules.isEmpty else { return nil }
        guard let rule = match(host: host, in: rules) else { return nil }
        if kind == .newTab, !rule.routesNewTabs { return nil }
        guard knownSpaceIDs.contains(rule.spaceID) else { return nil }
        return rule.spaceID
    }
}
