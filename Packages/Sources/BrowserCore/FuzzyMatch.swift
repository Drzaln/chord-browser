import Foundation

/// Subsequence scoring for the command bar.
///
/// Pure and dependency-free so ranking is testable without a UI, a database, or
/// a clock. Higher is better; `nil` means the query does not match at all.
public enum FuzzyMatch {

    /// Tuned so the obvious answer wins: an exact prefix beats a scattered
    /// subsequence, and matching at word starts beats matching mid-word.
    private enum Score {
        static let exact = 200
        static let prefix = 120
        static let wordStart = 15
        static let consecutive = 10
        static let matchedCharacter = 4
        static let gapPenalty = 1
        static let trailingLengthPenalty = 1
    }

    public static func score(query: String, candidate: String) -> Int? {
        let needle = query.lowercased()
        let haystack = candidate.lowercased()

        guard !needle.isEmpty else { return 0 }
        guard needle.count <= haystack.count else { return nil }

        // Bonuses, not replacements: a flat exact score can be beaten by a
        // prefix match that accumulates enough per-character credit.
        var total = 0
        if haystack.hasPrefix(needle) { total += Score.prefix }
        if haystack == needle { total += Score.exact }

        var haystackIndex = haystack.startIndex
        var previousMatchIndex: String.Index?
        var isWordBoundary = true

        for character in needle {
            var found = false

            while haystackIndex < haystack.endIndex {
                let current = haystack[haystackIndex]
                let nextIndex = haystack.index(after: haystackIndex)

                if current == character {
                    total += Score.matchedCharacter
                    if isWordBoundary { total += Score.wordStart }
                    if let previous = previousMatchIndex,
                       haystack.index(after: previous) == haystackIndex {
                        total += Score.consecutive
                    }
                    previousMatchIndex = haystackIndex
                    haystackIndex = nextIndex
                    isWordBoundary = Self.isSeparator(current)
                    found = true
                    break
                }

                total -= Score.gapPenalty
                isWordBoundary = Self.isSeparator(current)
                haystackIndex = nextIndex
            }

            guard found else { return nil }
        }

        // Among equally-matching candidates, prefer the shorter one: "git" should
        // rank github.com above a long URL that happens to contain the letters.
        total -= (haystack.count - needle.count) / 8 * Score.trailingLengthPenalty
        return total
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == " " || character == "/" || character == "." || character == "-"
            || character == "_" || character == "?" || character == "&" || character == ":"
    }

    /// Best score across several fields — a page matches on its title *or* its
    /// URL, whichever reads better.
    public static func bestScore(query: String, candidates: [String]) -> Int? {
        candidates.compactMap { score(query: query, candidate: $0) }.max()
    }
}
