import Foundation

/// Converts Adblock Plus filter syntax (EasyList, EasyPrivacy) into the
/// `WKContentRuleList` JSON WebKit compiles (content-blocking milestone C1).
///
/// **This is a subset, on purpose.** `WKContentRuleList` cannot express all of
/// ABP — no scriptlets, no `:has()`/extended cosmetics, no request redirection —
/// and Apple caps a compiled list at ~150k rules. So the converter handles the
/// high-value majority and *drops and counts* what it cannot represent, rather
/// than emitting something subtly wrong. See ADR (content-blocking) for why the
/// native path is a subset regardless of how the JSON is produced.
///
/// Supported:
/// - **Network rules** — `||host^`, `|start`, `end|`, `*` wildcards, `^`
///   separators, plain substrings.
/// - **Exceptions** — `@@…` → `ignore-previous-rules`.
/// - **Options** — `$third-party` / `$~third-party` / `$first-party`
///   (`load-type`), `$domain=a.com|~b.com` (`if-domain` / `unless-domain`),
///   resource types (`$script,image,stylesheet,font,media,xmlhttprequest,…`),
///   `$match-case`.
/// - **Element hiding** — `##selector`, `###id`, `domain##selector` →
///   `css-display-none`.
///
/// Dropped (counted): regex literals (`/…/`), scriptlet/extended-CSS cosmetics
/// (`#%#`, `#$#`, `#?#`, `#@#`), negated resource types (`$~script`), and any
/// rule carrying an option we do not map (`redirect`, `csp`, `removeparam`, …),
/// because honouring them wrong is worse than not blocking.
public enum ContentBlockConverter {
    public struct Result: Equatable {
        /// The converted rules, in source order.
        public var rules: [ContentBlockRule]
        /// Non-comment, non-blank lines seen.
        public var parsedLines: Int
        /// Lines that were a real filter but could not be represented.
        public var skipped: Int

        public init(rules: [ContentBlockRule], parsedLines: Int, skipped: Int) {
            self.rules = rules
            self.parsedLines = parsedLines
            self.skipped = skipped
        }
    }

    /// Converts a whole filter list (many lines) into rules plus counts.
    public static func convert(_ filterList: String) -> Result {
        var rules: [ContentBlockRule] = []
        var parsed = 0
        var skipped = 0

        for rawLine in filterList.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[Adblock") {
                continue  // comment / header / blank — not a filter, not "skipped"
            }
            parsed += 1
            if let rule = convertLine(line) {
                rules.append(rule)
            } else {
                skipped += 1
            }
        }
        return Result(rules: rules, parsedLines: parsed, skipped: skipped)
    }

    /// Converts a single filter line, or `nil` if it cannot be represented.
    static func convertLine(_ line: String) -> ContentBlockRule? {
        // Element hiding and its cousins all carry a `#` marker. Detect the
        // cosmetic variants first so a `#` inside a network pattern is not
        // mistaken for one.
        if let cosmetic = cosmeticRule(line) {
            return cosmetic
        }
        if isCosmeticButUnsupported(line) {
            return nil
        }
        return networkRule(line)
    }

    // MARK: - Cosmetic (element hiding)

    /// `##`, but not the unsupported `#@#` / `#?#` / `#$#` / `#%#` variants.
    private static func cosmeticRule(_ line: String) -> ContentBlockRule? {
        guard let range = line.range(of: "##") else { return nil }
        // Reject the extended markers that merely happen to contain "##" is not
        // possible — those use distinct separators — but a `#@#` before a `##`
        // would; `isCosmeticButUnsupported` covers those and runs when this
        // returns nil for them.
        let domainPart = String(line[line.startIndex..<range.lowerBound])
        let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty else { return nil }
        // Extended-CSS selectors WebKit can't compile.
        if selector.contains(":has(") || selector.contains(":-abp-")
            || selector.contains(":contains(") || selector.contains(":matches-css")
        {
            return nil
        }

        var ifDomain: [String] = []
        var unlessDomain: [String] = []
        for domain in domainPart.split(separator: ",") where !domain.isEmpty {
            if domain.hasPrefix("~") {
                unlessDomain.append("*" + domain.dropFirst())
            } else {
                ifDomain.append("*" + domain)
            }
        }

        let trigger = ContentBlockRule.Trigger(
            urlFilter: ".*",
            ifDomain: ifDomain.isEmpty ? nil : ifDomain,
            unlessDomain: unlessDomain.isEmpty ? nil : unlessDomain
        )
        return ContentBlockRule(
            trigger: trigger,
            action: ContentBlockRule.Action(type: .cssDisplayNone, selector: selector)
        )
    }

    private static func isCosmeticButUnsupported(_ line: String) -> Bool {
        line.contains("#@#") || line.contains("#?#") || line.contains("#$#")
            || line.contains("#%#")
    }

    // MARK: - Network

    private static func networkRule(_ line: String) -> ContentBlockRule? {
        var body = line
        let isException = body.hasPrefix("@@")
        if isException { body.removeFirst(2) }

        // Split off options at the last `$`. A `/regex/` literal is dropped
        // before this, so a `$` here is an options separator.
        var pattern = body
        var optionString: Substring = ""
        if let dollar = body.lastIndex(of: "$") {
            pattern = String(body[body.startIndex..<dollar])
            optionString = body[body.index(after: dollar)...]
        }

        // Regex literals: valid ABP, but Apple's url-filter is a *different*,
        // restricted regex, so passing one through risks silent misfires. Drop.
        if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count > 1 {
            return nil
        }

        guard var trigger = parseOptions(optionString) else { return nil }
        trigger.urlFilter = urlFilter(from: pattern)

        return ContentBlockRule(
            trigger: trigger,
            action: ContentBlockRule.Action(type: isException ? .ignorePreviousRules : .block)
        )
    }

    /// Maps ABP option tokens onto a trigger, or `nil` if any token is one we
    /// cannot honour (so the whole rule is dropped rather than half-applied).
    private static func parseOptions(_ options: Substring) -> ContentBlockRule.Trigger? {
        var trigger = ContentBlockRule.Trigger(urlFilter: ".*")
        if options.isEmpty { return trigger }

        var resourceTypes: [String] = []
        for token in options.split(separator: ",") {
            let opt = String(token)
            switch opt {
            case "third-party": trigger.loadType = ["third-party"]
            case "~third-party", "first-party": trigger.loadType = ["first-party"]
            case "match-case": trigger.urlFilterIsCaseSensitive = true
            case "important", "": break  // no matching effect we need to model
            default:
                if opt.hasPrefix("domain=") {
                    apply(domainOption: String(opt.dropFirst("domain=".count)), to: &trigger)
                } else if let apple = resourceTypeMap[opt] {
                    resourceTypes.append(apple)
                } else {
                    // Negated resource types and unmapped modifiers (redirect,
                    // csp, removeparam, popup, generichide, …): dropping the rule
                    // beats blocking the wrong thing.
                    return nil
                }
            }
        }
        if !resourceTypes.isEmpty { trigger.resourceType = resourceTypes }
        return trigger
    }

    private static func apply(domainOption: String, to trigger: inout ContentBlockRule.Trigger) {
        var ifDomain: [String] = []
        var unlessDomain: [String] = []
        for domain in domainOption.split(separator: "|") where !domain.isEmpty {
            if domain.hasPrefix("~") {
                unlessDomain.append("*" + domain.dropFirst())
            } else {
                ifDomain.append("*" + domain)
            }
        }
        if !ifDomain.isEmpty { trigger.ifDomain = ifDomain }
        if !unlessDomain.isEmpty { trigger.unlessDomain = unlessDomain }
    }

    private static let resourceTypeMap: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet",
        "font": "font", "media": "media", "xmlhttprequest": "raw",
        "ping": "ping", "websocket": "websocket", "document": "document",
        "subdocument": "document", "popup": "popup", "other": "other",
    ]

    // MARK: - URL-filter regex

    /// Translates an ABP network pattern into an Apple `url-filter` regex.
    static func urlFilter(from pattern: String) -> String {
        var body = Substring(pattern)
        var prefix = ""
        var suffix = ""

        if body.hasPrefix("||") {
            // Domain anchor: match the scheme then an optional subdomain chain.
            body = body.dropFirst(2)
            prefix = #"^https?://([^/]*\.)?"#
        } else if body.hasPrefix("|") {
            body = body.dropFirst()
            prefix = "^"
        }
        if body.hasSuffix("|") {
            body = body.dropLast()
            suffix = "$"
        }

        var rx = ""
        for ch in body {
            switch ch {
            case "*": rx += ".*"
            // `^` is an ABP separator: any char that is not part of a hostname
            // or path token. ABP also lets it match the end of the URL, but
            // Apple's url-filter regex engine rejects disjunctions (`(?:…|$)`
            // fails to compile — verified against WKContentRuleListStore), so we
            // use the character class alone. In practice a resource URL carries
            // a trailing `/`, `:`, or `?`, which the class matches.
            case "^": rx += "[^a-zA-Z0-9_.%-]"
            case ".", "$", "+", "?", "(", ")", "[", "]", "{", "}", "|", "\\":
                rx += "\\" + String(ch)
            default: rx += String(ch)
            }
        }

        let result = prefix + rx + suffix
        return result.isEmpty ? ".*" : result
    }
}
