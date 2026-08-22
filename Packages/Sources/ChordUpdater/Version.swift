import Foundation

/// A semantic version (major.minor.patch, optional `-prerelease`). Handles the
/// `v` prefix GitHub tags carry and compares per SemVer precedence — a
/// prerelease sorts before the corresponding release, so `1.3.0-beta` is not an
/// update over `1.2.0` but `1.3.0` is.
public struct Version: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot-separated prerelease identifiers (`beta.1`), or nil for a release.
    public let prerelease: [String]?

    public init?(raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let core = text.split(separator: "-", maxSplits: 1).map(String.init)
        guard let numeric = core.first else { return nil }
        let prereleasePart = core.count > 1 ? core[1] : nil

        let components = numeric.split(separator: ".").map(String.init)
        guard let major = Int(components.first ?? "") else { return nil }
        self.major = major
        self.minor = components.count > 1 ? (Int(components[1]) ?? 0) : 0
        self.patch = components.count > 2 ? (Int(components[2]) ?? 0) : 0

        if let prereleasePart {
            let ids = prereleasePart.split(separator: ".").map(String.init)
            guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }) else { return nil }
            self.prerelease = ids
        } else {
            self.prerelease = nil
        }
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        return Self.comparePrerelease(lhs.prerelease, rhs.prerelease) == .orderedAscending
    }

    private static func comparePrerelease(_ a: [String]?, _ b: [String]?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _?): return .orderedDescending // a release sorts after any prerelease
        case (_?, nil): return .orderedAscending
        case let (a?, b?):
            let count = min(a.count, b.count)
            for index in 0..<count {
                let x = a[index], y = b[index]
                if x == y { continue }
                let xInt = Int(x), yInt = Int(y)
                switch (xInt, yInt) {
                case let (xi?, yi?): return xi < yi ? .orderedAscending : .orderedDescending
                case (_?, nil): return .orderedAscending // numeric identifiers sort first
                case (nil, _?): return .orderedDescending
                default: return x < y ? .orderedAscending : .orderedDescending
                }
            }
            if a.count == b.count { return .orderedSame }
            return a.count < b.count ? .orderedAscending : .orderedDescending
        }
    }

    public var description: String {
        var text = "\(major).\(minor).\(patch)"
        if let prerelease { text += "-" + prerelease.joined(separator: ".") }
        return text
    }
}