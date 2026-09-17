import AppKit
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

    /// Whether label text on a surface tinted with `accent` should be dark. The
    /// accent is painted at `overlayOpacity` over the material, which the
    /// appearance approximates as near-white (light) or near-black (dark); the
    /// **higher-contrast** of black/white wins. Black and white cross at
    /// relative luminance ≈ 0.179 (both ≈4.58:1 there), so the choice keeps the
    /// label readable instead of a fixed 0.5 threshold that picks the weaker
    /// colour on a mid-tone Space.
    static func prefersDarkText(
        accent: ColorHex, isDarkAppearance: Bool, overlayOpacity: Double = 0.4
    ) -> Bool {
        guard let c = accent.components else { return !isDarkAppearance }
        return prefersDarkText(
            red: c.red, green: c.green, blue: c.blue,
            isDarkAppearance: isDarkAppearance, overlayOpacity: overlayOpacity
        )
    }

    /// The contrast ratio the chosen label colour achieves against the painted
    /// surface — the worst case is the ≈4.58:1 crossover, so this is always at
    /// least AA for small UI text.
    static func toastLabelContrast(
        accent: ColorHex, isDarkAppearance: Bool, overlayOpacity: Double = 0.4
    ) -> Double {
        guard let c = accent.components else { return 1 }
        return labelContrast(
            red: c.red, green: c.green, blue: c.blue,
            isDarkAppearance: isDarkAppearance, overlayOpacity: overlayOpacity
        )
    }

    /// The contrast the chosen `foregroundPair(on:)` primary achieves against
    /// the painted surface — for the surfaces whose tint is a `Color` rather
    /// than a stored `ColorHex`. `nil` when the colour cannot be resolved.
    static func toastLabelContrast(
        on tint: Color, isDarkAppearance: Bool, overlayOpacity: Double = 0.4
    ) -> Double? {
        guard let rgb = rgb(of: tint) else { return nil }
        return labelContrast(
            red: rgb.red, green: rgb.green, blue: rgb.blue,
            isDarkAppearance: isDarkAppearance, overlayOpacity: overlayOpacity
        )
    }

    /// A `primary`/`secondary` foreground pair that reads on a surface painted
    /// with `tint` at `overlayOpacity` — a selected sidebar row, a picked
    /// command-bar row, a toast capsule. `primary` is the higher-contrast of
    /// black/white; `secondary` is a dimmer form of it for the hierarchy
    /// `.secondary` normally carries. `nil` when the tint has no resolvable
    /// colour, so callers keep the system styles.
    static func foregroundPair(
        on tint: Color, isDarkAppearance: Bool, overlayOpacity: Double = 0.4
    ) -> (primary: Color, secondary: Color)? {
        guard let rgb = rgb(of: tint) else { return nil }
        let background = paintedLuminance(
            red: rgb.red, green: rgb.green, blue: rgb.blue,
            isDarkAppearance: isDarkAppearance, overlayOpacity: overlayOpacity
        )
        if blackContrast(background) >= whiteContrast(background) {
            return (Color.black.opacity(0.88), Color.black.opacity(0.55))
        }
        return (.white, Color.white.opacity(0.72))
    }

    private static func rgb(of tint: Color) -> (red: Double, green: Double, blue: Double)? {
        guard let srgb = NSColor(tint).usingColorSpace(.sRGB) else { return nil }
        return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
    }

    private static func prefersDarkText(
        red: Double, green: Double, blue: Double,
        isDarkAppearance: Bool, overlayOpacity: Double
    ) -> Bool {
        let background = paintedLuminance(
            red: red, green: green, blue: blue,
            isDarkAppearance: isDarkAppearance, overlayOpacity: overlayOpacity
        )
        return blackContrast(background) >= whiteContrast(background)
    }

    private static func labelContrast(
        red: Double, green: Double, blue: Double,
        isDarkAppearance: Bool, overlayOpacity: Double
    ) -> Double {
        let background = paintedLuminance(
            red: red, green: green, blue: blue,
            isDarkAppearance: isDarkAppearance, overlayOpacity: overlayOpacity
        )
        return max(blackContrast(background), whiteContrast(background))
    }

    /// sRGB → relative luminance (WCAG): composite the tint over the base, then
    /// linearise each gamma-encoded channel before weighting.
    private static func paintedLuminance(
        red: Double, green: Double, blue: Double,
        isDarkAppearance: Bool, overlayOpacity: Double
    ) -> Double {
        let base = isDarkAppearance ? 0.11 : 1.0
        func painted(_ channel: Double) -> Double {
            let composited = overlayOpacity * channel + (1 - overlayOpacity) * base
            return composited <= 0.04045
                ? composited / 12.92
                : pow((composited + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * painted(red) + 0.7152 * painted(green) + 0.0722 * painted(blue)
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
