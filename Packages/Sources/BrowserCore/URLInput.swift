import Foundation

/// Turns whatever the user typed into something navigable.
///
/// Pure and dependency-free so it is unit-testable, and so the command bar (M3)
/// can reuse it unchanged.
public enum URLInput {
    public static let searchTemplate = "https://duckduckgo.com/?q="

    public static func resolve(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }

        if looksLikeHost(text), let url = URL(string: "https://\(text)") {
            return url
        }

        return search(for: text)
    }

    public static func search(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? query
        return URL(string: searchTemplate + encoded)
    }

    /// A single token with a dot and no spaces is a host; anything else is a
    /// search. Deliberately conservative — guessing wrong sends the user to a
    /// DNS error instead of results.
    private static func looksLikeHost(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        let head = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        guard head.contains(".") else { return text == "localhost" }
        guard let last = head.split(separator: ".").last, last.count >= 2 else { return false }
        return last.allSatisfy(\.isLetter)
    }
}
