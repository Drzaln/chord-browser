import Foundation

/// The User-Agent the browser presents to sites (non-spec: user-requested).
///
/// `.default` keeps the browser's own completed Safari UA (the engine fills in
/// the `Version/…​ Safari/…` token). The presets and `.custom` override the whole
/// string via `WKWebView.customUserAgent`, for the handful of sites that sniff
/// for a specific browser or serve a better mobile layout.
///
/// Pure and `Codable` so it persists to `UserDefaults` and stays unit-testable;
/// no WebKit type appears here. The preset strings are hard-coded and will go
/// stale — the same accepted cost as the engine's Safari version token — because
/// there is no API to read a live UA for another browser.
public enum UserAgentPreference: Codable, Hashable, Sendable {
    /// The browser's own UA — `customUserAgent` is left unset.
    case `default`
    case chrome
    case firefox
    /// Mobile Safari on iPhone, for sites with a better phone layout.
    case safariIPhone
    /// Any user-supplied string. Empty is treated as `.default`.
    case custom(String)

    /// The presets offered as ready-made choices in Settings, in menu order.
    /// `.custom` is presented separately with its text field.
    public static let presets: [UserAgentPreference] = [
        .default, .chrome, .firefox, .safariIPhone,
    ]

    /// A representative full macOS Safari UA, used only to pre-fill the editable
    /// custom field when starting from `.default` — whose real UA the engine
    /// completes at runtime and which the UI layer cannot read. Plausible but
    /// static, the same accepted staleness as the engine's version token.
    public static let defaultTemplate =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    /// The string to seed a manual edit from: the resolved override, or the
    /// default template when nothing overrides the UA.
    public var editableTemplate: String { resolvedUserAgent ?? Self.defaultTemplate }

    public var displayName: String {
        switch self {
        case .default: "Default (this browser)"
        case .chrome: "Google Chrome"
        case .firefox: "Mozilla Firefox"
        case .safariIPhone: "Safari — iPhone"
        case .custom: "Custom…"
        }
    }

    /// The string to hand `WKWebView.customUserAgent`, or `nil` to leave the
    /// browser's own UA in place. An empty custom string is `nil`, not a blank UA.
    public var resolvedUserAgent: String? {
        switch self {
        case .default:
            return nil
        case .chrome:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Chrome/126.0.0.0 Safari/537.36"
        case .firefox:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:127.0) "
                + "Gecko/20100101 Firefox/127.0"
        case .safariIPhone:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                + "Version/17.5 Mobile/15E148 Safari/604.1"
        case .custom(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
