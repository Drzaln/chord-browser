import SwiftUI

/// The sidebar's, address field's and command bar's sizes, scaled by the
/// system text size (gn0.10, decided 2026-11-12).
///
/// The compact look is deliberate, so the base values are the fixed ones Chord
/// always had (`Metrics`, 12 pt row titles). What changes is that they follow
/// `dynamicTypeSize`: at the default size every value here equals its base, and
/// a larger text size grows text, row height and favicon together so rows do
/// not clip.
///
/// One value per text size, built once (`ChromeMetrics.resolved(for:)`) and
/// handed down through the environment. A row reads fonts and heights from it;
/// it computes nothing in `body` (§6.4).
public struct ChromeMetrics: Equatable, Sendable {
    public let scale: CGFloat

    public let sidebarRowHeight: CGFloat
    public let faviconSize: CGFloat
    public let pinnedTileHeight: CGFloat
    public let pinnedFaviconSize: CGFloat
    public let addressFieldHeight: CGFloat

    /// A tab row's title (12 pt at the default size).
    public let rowTitleFont: Font
    /// A tab row's small trailing glyphs: mute, sleep timer, close (9 pt).
    public let rowGlyphFont: Font
    /// The globe shown when a tab has no favicon (11 pt).
    public let rowPlaceholderFont: Font

    public init(scale: CGFloat) {
        self.scale = scale
        sidebarRowHeight = (Metrics.sidebarRowHeight * scale).rounded()
        faviconSize = (Metrics.faviconSize * scale).rounded()
        pinnedTileHeight = (Metrics.pinnedTileHeight * scale).rounded()
        pinnedFaviconSize = (20 * scale).rounded()
        addressFieldHeight = (Metrics.addressFieldHeight * scale).rounded()
        rowTitleFont = .system(size: Self.points(12, scale: scale))
        rowGlyphFont = .system(size: Self.points(9, scale: scale), weight: .semibold)
        rowPlaceholderFont = .system(size: Self.points(11, scale: scale))
    }

    /// A base point size at this scale, to the half point.
    public func points(_ base: CGFloat) -> CGFloat {
        Self.points(base, scale: scale)
    }

    /// A system font at a base size, scaled.
    public func font(_ base: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: points(base), weight: weight)
    }

    static func points(_ base: CGFloat, scale: CGFloat) -> CGFloat {
        (base * scale * 2).rounded() / 2
    }

    /// The default text size: every value equals the fixed size Chord had.
    public static let standard = ChromeMetrics(scale: 1)

    /// How much the chrome grows at each text size. `large` is the system
    /// default. Chrome grows more slowly than body text does and stops at 2x:
    /// the sidebar keeps its width, so past that a title is all ellipsis.
    static func scale(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.85
        case .small: 0.9
        case .medium: 0.95
        case .large: 1
        case .xLarge: 1.1
        case .xxLarge: 1.2
        case .xxxLarge: 1.3
        case .accessibility1: 1.45
        case .accessibility2: 1.6
        case .accessibility3: 1.75
        case .accessibility4: 1.9
        case .accessibility5: 2
        @unknown default: 1
        }
    }

    private static let table: [DynamicTypeSize: ChromeMetrics] = Dictionary(
        uniqueKeysWithValues: DynamicTypeSize.allCases.map {
            ($0, ChromeMetrics(scale: scale(for: $0)))
        }
    )

    /// The metrics for a text size, from a table built once.
    public static func resolved(for size: DynamicTypeSize) -> ChromeMetrics {
        table[size] ?? .standard
    }
}

private struct ChromeMetricsKey: EnvironmentKey {
    static let defaultValue = ChromeMetrics.standard
}

extension EnvironmentValues {
    public var chromeMetrics: ChromeMetrics {
        get { self[ChromeMetricsKey.self] }
        set { self[ChromeMetricsKey.self] = newValue }
    }
}

/// Reads the text size once, at the top of a window, and publishes the
/// matching metrics to everything below.
private struct ChromeMetricsProvider: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.environment(\.chromeMetrics, .resolved(for: dynamicTypeSize))
    }
}

extension View {
    /// Makes `chromeMetrics` follow the text size for this view tree.
    public func followsSystemTextSize() -> some View {
        modifier(ChromeMetricsProvider())
    }
}
