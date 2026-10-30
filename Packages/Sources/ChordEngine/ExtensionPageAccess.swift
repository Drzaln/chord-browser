import Foundation

/// Which site may send a tab to an extension's page. Ported from Search's
/// `ExtensionRedirectPolicy`: a site may open only a file the manifest's
/// `web_accessible_resources` exposes to it, and a declaration Chord can't read
/// is refused, never read more permissively.
///
/// Unlike Search, plain http sites are allowed as Chrome allows them: a
/// declarativeNetRequest redirect (Norma's blocked-site page) reaches the
/// policy as an ordinary navigation from the site, not marked as a rule's, so
/// it can't be told apart and still has to work for http sites.
enum ExtensionPageAccess {
    static let schemes: Set<String> = ["chrome-extension", "webkit-extension"]

    static func isExtensionPage(_ url: URL?) -> Bool {
        schemes.contains(url?.scheme?.lowercased() ?? "")
    }

    /// A declarativeNetRequest redirect to an extension's own file arrives with
    /// its `?` and `#` escaped into the path: WebKit sets the rule's
    /// `extensionPath` as a path, where Chrome reads "/blocked.html#site" as a
    /// file and a fragment. The first escaped one is put back as Chrome reads
    /// it. Anything else is left as it is.
    static func ruleTarget(_ target: URL) -> URL {
        guard var components = URLComponents(url: target, resolvingAgainstBaseURL: false),
            components.percentEncodedQuery == nil, components.percentEncodedFragment == nil
        else { return target }
        let path = components.percentEncodedPath
        let lower = path.lowercased()
        let query = lower.range(of: "%3f")
        let fragment = lower.range(of: "%23")
        guard let first = [query, fragment].compactMap({ $0 })
            .min(by: { $0.lowerBound < $1.lowerBound })
        else { return target }
        let at = path.index(
            path.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: first.lowerBound)
        )
        let rest = String(path[path.index(at, offsetBy: 3)...])
        components.percentEncodedPath = String(path[..<at])
        if first == query {
            let restLower = rest.lowercased()
            if let hash = restLower.range(of: "%23") {
                let split = rest.index(
                    rest.startIndex,
                    offsetBy: restLower.distance(from: restLower.startIndex, to: hash.lowerBound)
                )
                components.percentEncodedQuery = String(rest[..<split])
                components.percentEncodedFragment = String(rest[rest.index(split, offsetBy: 3)...])
            } else {
                components.percentEncodedQuery = rest
            }
        } else {
            components.percentEncodedFragment = rest
        }
        return components.url ?? target
    }

    /// Whether a page at `source` may open `target`, one of the extension's
    /// files, given that extension's manifest.
    static func allows(target: URL, source: URL, manifest: [String: Any]) -> Bool {
        let sourceScheme = source.scheme?.lowercased() ?? ""
        guard isExtensionPage(target),
            target.host != nil, target.user == nil, target.password == nil, target.port == nil,
            sourceScheme == "https" || sourceScheme == "http",
            source.host != nil, source.user == nil, source.password == nil,
            let components = URLComponents(url: target, resolvingAgainstBaseURL: false)
        else { return false }

        // Fail closed on encodings with inconsistent path interpretations.
        let encoded = components.percentEncodedPath
        let lower = encoded.lowercased()
        guard encoded.hasPrefix("/"),
            !lower.contains("%2f"), !lower.contains("%5c"),
            let decoded = encoded.removingPercentEncoding,
            !decoded.contains("\\"), !decoded.contains("%"),
            !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        let path = String(decoded.dropFirst())
        guard !path.isEmpty,
            !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
        else { return false }

        guard (manifest["manifest_version"] as? Int) == 3,
            let rules = manifest["web_accessible_resources"] as? [[String: Any]]
        else { return false }
        return rules.contains { rule in
            // A dynamic extension origin needs its own handling; refused here.
            if let dynamic = rule["use_dynamic_url"] {
                guard let enabled = dynamic as? Bool, !enabled else { return false }
            }
            guard let resources = rule["resources"] as? [String],
                let origins = rule["matches"] as? [String],
                resources.contains(where: { resource(path, matches: $0) })
            else { return false }
            return origins.contains { origin(source, matches: $0) }
        }
    }

    private static func resource(_ path: String, matches pattern: String) -> Bool {
        // Only the '*' wildcard. Other regex metacharacters stay literal.
        guard !pattern.isEmpty, !pattern.contains("\\"), !pattern.contains("%"),
            !pattern.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        let clean = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
        guard !clean.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
        else { return false }
        let expression = "\\A" + clean.components(separatedBy: "*")
            .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: ".*") + "\\z"
        guard let regex = try? NSRegularExpression(pattern: expression) else { return false }
        return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    private static func origin(_ source: URL, matches pattern: String) -> Bool {
        // MV3 origin patterns have a /* path. Unsupported syntax is refused.
        if pattern == "<all_urls>" { return true }
        guard let separator = pattern.range(of: "://"), let host = source.host?.lowercased()
        else { return false }
        let scheme = String(pattern[..<separator.lowerBound]).lowercased()
        guard scheme == source.scheme?.lowercased() || scheme == "*" else { return false }
        let remainder = String(pattern[separator.upperBound...])
        guard let slash = remainder.firstIndex(of: "/"), remainder[slash...] == "/*"
        else { return false }
        let allowed = String(remainder[..<slash]).lowercased()
        guard !allowed.isEmpty, !allowed.contains(":"), !allowed.contains("@"),
            !allowed.contains("%"), !allowed.contains("\\")
        else { return false }
        if allowed == "*" { return true }
        if allowed.hasPrefix("*.") {
            let suffix = String(allowed.dropFirst(2))
            guard !suffix.isEmpty, !suffix.contains("*") else { return false }
            return host == suffix || host.hasSuffix("." + suffix)
        }
        return !allowed.contains("*") && host == allowed
    }
}
