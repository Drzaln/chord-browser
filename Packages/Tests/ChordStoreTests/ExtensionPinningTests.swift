import Foundation
import Testing

@testable import ChordStore

/// Which extensions keep a button in the address field (21n).
@Suite("Extension pinning")
@MainActor
struct ExtensionPinningTests {

    @Test("The first run pins everything already installed, so the bar looks the same")
    func existingExtensionsStartPinned() {
        let prefs = InMemoryPreferenceStore()
        let pins = ExtensionPinning(preferences: prefs) { ["bitwarden", "loom"] }

        #expect(pins.isPinned("bitwarden"))
        #expect(pins.isPinned("loom"))
    }

    @Test("An extension installed later starts unpinned")
    func newInstallStartsUnpinned() {
        let prefs = InMemoryPreferenceStore()
        _ = ExtensionPinning(preferences: prefs) { ["bitwarden"] }

        // Next launch: the library has grown, but the migration already ran.
        let pins = ExtensionPinning(preferences: prefs) { ["bitwarden", "newcomer"] }

        #expect(pins.isPinned("bitwarden"))
        #expect(!pins.isPinned("newcomer"), "a new install must not grow the bar")
    }

    @Test("Pin changes survive a relaunch")
    func pinStatePersists() {
        let prefs = InMemoryPreferenceStore()
        let pins = ExtensionPinning(preferences: prefs) { ["a", "b"] }
        pins.setPinned(false, slug: "a")
        pins.setPinned(true, slug: "c")

        let relaunched = ExtensionPinning(preferences: prefs) { ["a", "b", "c"] }
        #expect(relaunched.pinnedSlugs == ["b", "c"])
    }

    @Test("A removed extension leaves no pin, so a reinstall starts unpinned")
    func forgetDropsThePin() {
        let prefs = InMemoryPreferenceStore()
        let pins = ExtensionPinning(preferences: prefs) { ["a"] }
        pins.forget("a")

        #expect(!pins.isPinned("a"))
        #expect(!ExtensionPinning(preferences: prefs) { ["a"] }.isPinned("a"))
    }
}
