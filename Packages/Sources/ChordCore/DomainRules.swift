import Foundation

/// Host-rule helpers shared by the per-domain override maps (User-Agent,
/// referrer).
///
/// One tested implementation of "clean up what the user typed" and "the most
/// specific rule wins", because a loose suffix match here is the same class of
/// mistake as a loose origin match in the vault — and it would be a mistake made
/// twice, once per map, if each carried its own copy.
enum DomainRules {

    /// Cleans up what the user typed into something matchable: accepts
    /// `https://meet.google.com/abc`, `meet.google.com`, or `.google.com` and
    /// returns `meet.google.com` / `google.com`. Nil when there is nothing
    /// usable left, so the UI can refuse to add an empty rule.
    static func normalise(_ input: String) -> String? {
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

    /// The rule that applies to `host`, or nil.
    ///
    /// A rule covers its subdomains — `google.com` matches `meet.google.com` —
    /// because that is what makes the map usable at all. **The suffix must be
    /// preceded by a dot**: `google.com` must never match `evil-google.com` or
    /// `notgoogle.com`, which is the whole reason this is one tested function
    /// rather than a `hasSuffix` at a call site.
    ///
    /// The **most specific** rule wins, so `meet.google.com → Default` can carve
    /// an exception out of `google.com → Chrome`.
    static func mostSpecific<Rule>(
        host: String, in rules: [Rule], domain: (Rule) -> String
    ) -> Rule? {
        let host = host.lowercased()
        return
            rules
            .filter { host == domain($0) || host.hasSuffix("." + domain($0)) }
            .max { domain($0).count < domain($1).count }
    }
}
