import ChordExtensions
import ChordStore
import Foundation
import Testing

@testable import ChordUI

/// How many extension buttons the address field shows (21n).
@Suite("Extension toolbar layout")
@MainActor
struct ExtensionToolbarLayoutTests {

    private func action(_ slug: String) -> ExtensionActionSnapshot {
        ExtensionActionSnapshot(
            slug: slug, spaceID: UUID(), label: slug, badgeText: "",
            presentsPopup: true, enabled: true, icon: nil
        )
    }

    @Test("Ten pinned extensions never squeeze the address below its minimum")
    func tenExtensionsKeepTheAddress() {
        // The default sidebar is 240 pt; the row sits inside its padding.
        for rowWidth in stride(from: 0, through: 600, by: 10) {
            let width = CGFloat(rowWidth)
            let count = ExtensionToolbarLayout.buttonCount(fitting: width)
            let used = CGFloat(count) * ExtensionToolbarLayout.slotWidth
                + ExtensionToolbarLayout.reservedWidth
            #expect(count >= 0)
            if count > 0 {
                #expect(width - used >= ExtensionToolbarLayout.minimumAddressWidth)
            }
        }
        #expect(ExtensionToolbarLayout.buttonCount(fitting: 224) < 10)
    }

    @Test("Only pinned actions show, in order, up to the limit")
    func showsPinnedUpToLimit() {
        let prefs = InMemoryPreferenceStore()
        let pins = ExtensionPinning(preferences: prefs) { ["a", "c", "d"] }
        let actions = ["a", "b", "c", "d"].map(action)

        #expect(ExtensionToolbarLayout.shown(actions, pins: pins, limit: .max).map(\.slug) == ["a", "c", "d"])
        #expect(ExtensionToolbarLayout.shown(actions, pins: pins, limit: 2).map(\.slug) == ["a", "c"])
        #expect(ExtensionToolbarLayout.shown(actions, pins: pins, limit: 0).isEmpty)
    }
}
