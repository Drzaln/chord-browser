import Foundation

/// One compiled content-blocking rule in the shape `WKContentRuleList` wants
/// (content-blocking milestone C1). This is Apple's content-blocker JSON —
/// an array of `{ "trigger": …, "action": … }` — **not** Adblock Plus filter
/// syntax; `ContentBlockConverter` produces these from EasyList/EasyPrivacy
/// lines.
///
/// WebKit-free by construction: this is a value type in `BrowserCore` that
/// serialises to the JSON string `BrowserEngine` later hands to
/// `WKContentRuleListStore.compileContentRuleList`. Keeping the shape and the
/// conversion here means the whole thing is unit-testable without WebKit (§3.6).
public struct ContentBlockRule: Encodable, Equatable {
    public var trigger: Trigger
    public var action: Action

    public init(trigger: Trigger, action: Action) {
        self.trigger = trigger
        self.action = action
    }

    /// The `trigger` object. `urlFilter` is a regular expression matched against
    /// the resource URL and is the only required field; the rest narrow when the
    /// rule applies.
    public struct Trigger: Encodable, Equatable {
        public var urlFilter: String
        public var urlFilterIsCaseSensitive: Bool?
        public var ifDomain: [String]?
        public var unlessDomain: [String]?
        public var resourceType: [String]?
        public var loadType: [String]?

        public init(
            urlFilter: String,
            urlFilterIsCaseSensitive: Bool? = nil,
            ifDomain: [String]? = nil,
            unlessDomain: [String]? = nil,
            resourceType: [String]? = nil,
            loadType: [String]? = nil
        ) {
            self.urlFilter = urlFilter
            self.urlFilterIsCaseSensitive = urlFilterIsCaseSensitive
            self.ifDomain = ifDomain
            self.unlessDomain = unlessDomain
            self.resourceType = resourceType
            self.loadType = loadType
        }

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case resourceType = "resource-type"
            case loadType = "load-type"
        }
    }

    /// The `action` object. `block` drops the request; `ignore-previous-rules`
    /// is how an EasyList exception (`@@`) whitelists; `css-display-none` hides
    /// elements matching `selector` (element-hiding rules, `##`).
    public struct Action: Encodable, Equatable {
        public var type: ActionType
        public var selector: String?

        public init(type: ActionType, selector: String? = nil) {
            self.type = type
            self.selector = selector
        }

        enum CodingKeys: String, CodingKey {
            case type
            case selector
        }
    }

    public enum ActionType: String, Encodable {
        case block
        case ignorePreviousRules = "ignore-previous-rules"
        case cssDisplayNone = "css-display-none"
    }
}

extension Array where Element == ContentBlockRule {
    /// Serialises to the compact JSON string `WKContentRuleListStore` compiles.
    /// Keys stay in a stable order and slashes are left unescaped so the output
    /// reads like the URLs it contains.
    public func contentRuleListJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
