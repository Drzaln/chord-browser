@testable import ChordUI
import SwiftUI
import Testing

/// gn0.10: the sidebar's sizes follow the system text size.
@Suite struct ChromeMetricsTests {
    @Test func theDefaultSizeIsTheFixedLookChordAlwaysHad() {
        let metrics = ChromeMetrics.resolved(for: .large)
        #expect(metrics == .standard)
        #expect(metrics.scale == 1)
        #expect(metrics.sidebarRowHeight == Metrics.sidebarRowHeight)
        #expect(metrics.faviconSize == Metrics.faviconSize)
        #expect(metrics.addressFieldHeight == Metrics.addressFieldHeight)
        #expect(metrics.pinnedTileHeight == Metrics.pinnedTileHeight)
        #expect(metrics.points(12) == 12)
        #expect(metrics.points(9) == 9)
    }

    @Test func everySizeGrowsNoSmallerThanTheOneBefore() {
        let scales = DynamicTypeSize.allCases.map(ChromeMetrics.scale(for:))
        #expect(scales == scales.sorted())
        #expect(scales.first == 0.85)
        #expect(scales.last == 2)
    }

    /// A row must stay taller than its text and its favicon at every size, or
    /// it clips.
    @Test func rowsNeverClipTheirTextOrFavicon() {
        for size in DynamicTypeSize.allCases {
            let metrics = ChromeMetrics.resolved(for: size)
            #expect(metrics.sidebarRowHeight >= metrics.points(12) * 1.5, "\(size)")
            #expect(metrics.sidebarRowHeight > metrics.faviconSize, "\(size)")
            #expect(metrics.pinnedTileHeight > metrics.pinnedFaviconSize, "\(size)")
            #expect(metrics.addressFieldHeight >= metrics.points(13) * 1.5, "\(size)")
        }
    }

    @Test func pointsRoundToTheHalfPoint() {
        let metrics = ChromeMetrics(scale: 1.1)
        #expect(metrics.points(12) == 13)      // 13.2
        #expect(metrics.points(9) == 10)       // 9.9
        #expect(metrics.points(11) == 12)      // 12.1
        #expect(ChromeMetrics(scale: 0.85).points(9) == 7.5)  // 7.65
    }

    /// §6.4: a tab row computes no font in `body`. The source must only read
    /// the fonts the metrics built once.
    @Test func theTabRowReadsFontsItDoesNotBuildThem() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChordUI/Sidebar/TabRowView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(!source.contains(".system(size:"))
        #expect(!source.contains("metrics.font("))
        #expect(source.contains("metrics.rowTitleFont"))
    }
}
