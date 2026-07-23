import Foundation

/// A hex colour, kept as a value type so `BrowserCore` needs no AppKit.
public struct ColorHex: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// Red, green, blue in 0...1, or nil if the string is not `#RRGGBB`.
    public var components: (red: Double, green: Double, blue: Double)? {
        var text = value
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let packed = UInt32(text, radix: 16) else { return nil }
        return (
            Double((packed >> 16) & 0xFF) / 255,
            Double((packed >> 8) & 0xFF) / 255,
            Double(packed & 0xFF) / 255
        )
    }

    /// Linear RGB interpolation between two hex colours. Used to blend a Space's
    /// gradient toward its neighbour's while a swipe is in flight (4.2). Returns
    /// `a` unchanged if either endpoint is not a `#RRGGBB` string.
    public static func lerp(_ a: ColorHex, _ b: ColorHex, t: Double) -> ColorHex {
        guard let ca = a.components, let cb = b.components else { return a }
        let clamped = max(0, min(1, t))
        func mix(_ x: Double, _ y: Double) -> Int {
            Int((x + (y - x) * clamped) * 255 + 0.5)
        }
        return ColorHex(
            String(format: "#%02X%02X%02X",
                   mix(ca.red, cb.red), mix(ca.green, cb.green), mix(ca.blue, cb.blue))
        )
    }
}

/// A named workspace with its own tab set and its own cookies.
///
/// The isolation is real WebKit isolation, not a filter: each Space maps to its
/// own `WKWebsiteDataStore`, so two accounts on the same site stay logged in
/// simultaneously (3.3).
public struct Space: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    /// SF Symbol name.
    public var iconSymbol: String
    /// Two or three stops, drives sidebar theming.
    public var gradient: [ColorHex]
    /// Maps to `WKWebsiteDataStore(forIdentifier:)`.
    public var dataStoreID: UUID
    public var sortIndex: Int
    /// Uses a non-persistent store instead; nothing survives a quit.
    public var isPrivate: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        iconSymbol: String = "circle.grid.2x2",
        gradient: [ColorHex] = Space.defaultGradient,
        dataStoreID: UUID = UUID(),
        sortIndex: Int,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.name = name
        self.iconSymbol = iconSymbol
        self.gradient = gradient
        self.dataStoreID = dataStoreID
        self.sortIndex = sortIndex
        self.isPrivate = isPrivate
    }

    /// Whether `iconSymbol` holds an emoji (or any custom glyph) rather than an
    /// SF Symbol name. SF Symbol names are always ASCII — letters, digits, dots
    /// — so any non-ASCII scalar means the icon should be drawn as text, not
    /// looked up as a symbol. Lets a Space carry an emoji without a second field
    /// or a schema change.
    public var isEmojiIcon: Bool {
        iconSymbol.unicodeScalars.contains { $0.value > 0x7F }
    }

    public static let defaultGradient: [ColorHex] = ["#5B7FFF", "#8E6BFF"]

    /// The Space a fresh profile starts with.
    public static func makeDefault() -> Space {
        Space(name: "Personal", iconSymbol: "person", sortIndex: 0)
    }

    /// Cycled through when the user adds a Space, so new Spaces are visually
    /// distinct without asking the user to pick colours.
    public static let palette: [[ColorHex]] = [
        ["#5B7FFF", "#8E6BFF"],
        ["#FF7A59", "#FF4D8D"],
        ["#20C997", "#0CA678"],
        ["#FFB020", "#FF7A59"],
        ["#845EF7", "#5B7FFF"],
    ]

    public static func gradient(forIndex index: Int) -> [ColorHex] {
        palette[abs(index) % palette.count]
    }
}
