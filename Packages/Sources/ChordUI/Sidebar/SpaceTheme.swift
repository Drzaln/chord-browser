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

    /// Whether label text on a toast tinted with `accent` should be dark. The
    /// accent is painted at `overlayOpacity` over the material, which the
    /// appearance approximates as near-white (light) or near-black (dark); the
    /// **higher-contrast** of black/white wins. Black and white cross at
    /// relative luminance ≈ 0.179 (both ≈4.58:1 there), so the choice keeps the
    /// label readable instead of a fixed 0.5 threshold that picks the weaker
    /// colour on a mid-tone Space.
    static func prefersDarkText(
        accent: ColorHex, isDarkAppearance: Bool, overlayOpacity: Double = 0.4
    ) -> Bool {
        let background = paintedLuminance(
            accent: accent, isDarkAppearance: isDarkAppearance, overlayOpacity: overlayOpacity
        )
        return blackContrast(background) >= whiteContrast(background)
    }

    /// The contrast ratio the chosen label colour achieves against the painted
    /// capsule — the worst case is the ≈4.58:1 crossover, so this is always at
    /// least AA for the toast's 12pt text.
    static func toastLabelContrast(
        accent: ColorHex, isDarkAppearance: Bool, overlayOpacity: Double = 0.4
    ) -> Double {
        let background = paintedLuminance(
            accent: accent, isDarkAppearance: isDarkAppearance, overlayOpacity: overlayOpacity
        )
        return max(blackContrast(background), whiteContrast(background))
    }

    /// sRGB → relative luminance (WCAG): composite the accent over the base, then
    /// linearise each gamma-encoded channel before weighting.
    private static func paintedLuminance(
        accent: ColorHex, isDarkAppearance: Bool, overlayOpacity: Double
    ) -> Double {
        guard let c = accent.components else { return isDarkAppearance ? 0 : 1 }
        let base = isDarkAppearance ? 0.11 : 1.0
        func painted(_ channel: Double) -> Double {
            let composited = overlayOpacity * channel + (1 - overlayOpacity) * base
            return composited <= 0.04045
                ? composited / 12.92
                : pow((composited + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * painted(c.red) + 0.7152 * painted(c.green) + 0.0722 * painted(c.blue)
    }

    private static func blackContrast(_ background: Double) -> Double { (background + 0.05) / 0.05 }
    private static func whiteContrast(_ background: Double) -> Double { 1.05 / (background + 0.05) }

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
