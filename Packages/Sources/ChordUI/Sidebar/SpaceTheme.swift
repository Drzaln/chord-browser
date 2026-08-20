import ChordCore
import SwiftUI

/// Turns a Space's stored hex stops into SwiftUI colours.
///
/// Conversion happens here and is cached, never in a view body — a gradient
/// rebuilt on every redraw is the same accidental CPU burn as decoding a
/// favicon per frame (6.4).
@MainActor
enum SpaceTheme {
    private static var cache: [UUID: (stops: [ColorHex], gradient: LinearGradient)] = [:]

    static func gradient(for space: Space) -> LinearGradient {
        if let cached = cache[space.id], cached.stops == space.gradient {
            return cached.gradient
        }

        let gradient = LinearGradient(
            colors: space.gradient.map(color(from:)),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        cache[space.id] = (space.gradient, gradient)
        return gradient
    }

    /// Builds a gradient from arbitrary stops, uncached. Only for the live
    /// swipe blend (4.2), where the stops change every frame and caching would
    /// churn — the idle sidebar still goes through `gradient(for:)`.
    static func gradient(stops: [ColorHex]) -> LinearGradient {
        LinearGradient(
            colors: stops.map(color(from:)),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func accent(for space: Space) -> Color {
        space.gradient.first.map(color(from:)) ?? .accentColor
    }

    static func forget(spaceID: UUID) {
        cache[spaceID] = nil
    }

    private static func color(from hex: ColorHex) -> Color {
        guard let components = hex.components else { return .accentColor }
        return Color(
            .sRGB,
            red: components.red,
            green: components.green,
            blue: components.blue,
            opacity: 1
        )
    }
}
