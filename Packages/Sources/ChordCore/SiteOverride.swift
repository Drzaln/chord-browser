import Foundation

/// One site's look-and-behaviour patch (non-spec: user-requested).
///
/// Deliberately not a theme model with colour and font fields: those would be
/// generators for the `css` below, and a browser that ships three half-working
/// styling systems ships none well. The record is the CSS, the JS, and the list
/// of elements the user zapped. See ADR 024.
public struct SiteOverride: Codable, Hashable, Sendable, Identifiable {
    /// The registrable domain or host this applies to, normalised. Covers
    /// subdomains, like the other per-domain maps.
    public let pattern: String
    /// Free-form CSS appended to the override stylesheet. Empty is normal.
    public var css: String
    /// Free-form JS run at document start on a matching page, in the page's own
    /// world. Trusted-local: it is the user's own code, the same trust as a
    /// snippet pasted into the Web Inspector.
    public var js: String
    /// Elements hidden by the zapper. Kept separate from `css` so the picker can
    /// append to it and the editor can list it in plain language rather than
    /// making the user read `display: none` rules among their own CSS.
    public var hiddenSelectors: [String]
    /// Off keeps the override without applying it.
    public var isEnabled: Bool

    public var id: String { pattern }

    public init(
        pattern: String,
        css: String = "",
        js: String = "",
        hiddenSelectors: [String] = [],
        isEnabled: Bool = true
    ) {
        self.pattern = pattern
        self.css = css
        self.js = js
        self.hiddenSelectors = hiddenSelectors
        self.isEnabled = isEnabled
    }

    /// Whether this override would actually do anything. An enabled override with
    /// no CSS, no JS and no zapped selectors is not worth a user script.
    public var hasContent: Bool {
        !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !hiddenSelectors.isEmpty
    }
}

/// What is injected for a site, and which site it applies to. Pure so the CSS
/// and the host matching can be tested without a web view.
public enum SiteOverrides {

    /// Cleans up a typed host, reusing the one matcher the per-domain maps share.
    public static func normalise(_ input: String) -> String? {
        DomainRules.normalise(input)
    }

    /// The enabled override that applies to `host`, most specific wins.
    public static func match(host: String, in overrides: [SiteOverride]) -> SiteOverride? {
        DomainRules.mostSpecific(host: host, in: overrides.filter(\.isEnabled)) { $0.pattern }
    }

    /// The stylesheet for one override: the zapped selectors first, then the
    /// user's CSS verbatim.
    ///
    /// Hiding is CSS rather than a mutation-polling script on purpose. A
    /// stylesheet outlives the DOM a single-page app rewrites, so an element
    /// zapped once stays zapped across a re-render; the alternative is the
    /// polling loop the YouTube blocker already pays for (ADR 013).
    public static func stylesheet(for override: SiteOverride) -> String {
        var parts: [String] = []
        for selector in override.hiddenSelectors {
            let cleaned = selector.trimmingCharacters(in: .whitespacesAndNewlines)
            // A selector carrying a declaration or a rule would break out of the
            // block it belongs in. Reject rather than ship a malformed sheet.
            guard !cleaned.isEmpty, !cleaned.contains(where: { "{};".contains($0) })
            else { continue }
            parts.append("\(cleaned) { display: none !important; }")
        }
        let css = override.css.trimmingCharacters(in: .whitespacesAndNewlines)
        if !css.isEmpty { parts.append(css) }
        return parts.joined(separator: "\n")
    }

    /// Whether a selector is safe to append to `hiddenSelectors`.
    public static func isUsableSelector(_ selector: String) -> Bool {
        let cleaned = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleaned.isEmpty && !cleaned.contains(where: { "{};".contains($0) })
    }
}
