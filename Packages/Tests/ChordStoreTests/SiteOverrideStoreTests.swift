import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// Site overrides (ADR 024): the store side — CRUD, persistence, and the push to
/// the engine. The injected-script text is covered in `ChordEngineTests`.
@Suite("Site overrides — store wiring")
@MainActor
struct SiteOverrideStoreTests {

    private func makeStore() -> (TabStore, FakeWebEngine) {
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine,
            repository: FakeTabRepository(),
            clock: FixedClock()
        )
        store.preferenceStore = InMemoryPreferenceStore()
        return (store, engine)
    }

    @Test("Saving an override normalises the host and reaches the engine")
    func saveReachesEngine() {
        let (store, engine) = makeStore()
        #expect(
            store.setSiteOverride(
                SiteOverride(pattern: "https://www.Example.com/a", css: "body { color: red; }")
            )
        )
        #expect(store.siteOverrides.count == 1)
        #expect(store.siteOverrides[0].pattern == "www.example.com")
        #expect(engine.appliedSiteOverrides.map(\.pattern) == ["www.example.com"])
        // One push at init, one for the save.
        #expect(engine.siteOverridesSetCount == 2)
    }

    @Test("Saving again replaces rather than duplicates")
    func saveReplaces() {
        let (store, _) = makeStore()
        store.setSiteOverride(SiteOverride(pattern: "example.com", css: "a {}"))
        store.setSiteOverride(SiteOverride(pattern: "example.com", css: "b {}"))
        #expect(store.siteOverrides.count == 1)
        #expect(store.siteOverrides[0].css == "b {}")
    }

    @Test("An unusable pattern is refused instead of stored")
    func rejectsBadPattern() {
        let (store, _) = makeStore()
        #expect(store.setSiteOverride(SiteOverride(pattern: "not a host")) == false)
        #expect(store.siteOverrides.isEmpty)
    }

    @Test("The zapper appends selectors, de-duplicates, and refuses junk")
    func hiddenSelectors() {
        let (store, _) = makeStore()
        store.setSiteOverride(SiteOverride(pattern: "example.com"))
        #expect(store.addHiddenSelector(".sidebar", to: "example.com"))
        #expect(store.addHiddenSelector(".sidebar", to: "example.com"))
        #expect(store.siteOverrides[0].hiddenSelectors == [".sidebar"])
        #expect(store.addHiddenSelector("a { color: red }", to: "example.com") == false)
        // No override for that site means nothing to write into.
        #expect(store.addHiddenSelector(".ad", to: "other.example") == false)

        store.removeHiddenSelector(".sidebar", from: "example.com")
        #expect(store.siteOverrides[0].hiddenSelectors.isEmpty)
    }

    @Test("Matching finds the most specific enabled override")
    func matching() {
        let (store, _) = makeStore()
        store.setSiteOverride(SiteOverride(pattern: "example.com", css: "a {}"))
        store.setSiteOverride(
            SiteOverride(pattern: "docs.example.com", css: "b {}", isEnabled: false)
        )
        #expect(store.siteOverride(forHost: "www.example.com")?.pattern == "example.com")
        #expect(store.siteOverride(forHost: "evil.test") == nil)
    }

    @Test("Overrides persist as preferences")
    func persists() {
        let (store, _) = makeStore()
        store.setSiteOverride(
            SiteOverride(pattern: "example.com", css: "p{}", hiddenSelectors: [".ad"])
        )
        let stored = Preferences.loadSiteOverrides(store.preferenceStore)
        #expect(stored.count == 1)
        #expect(stored[0].hiddenSelectors == [".ad"])
    }

    @Test("A pick from the site's own page is appended to that override")
    func pickFromMatchingHost() async {
        let (store, engine) = makeStore()
        await store.restore()
        store.setSiteOverride(SiteOverride(pattern: "example.com"))

        store.beginElementPick(forPattern: "example.com")
        #expect(engine.pickingPanes == [store.selectedTab!.focusedPaneID])

        store.panePickedSiteOverrideElement(
            selector: "#promo", host: "www.example.com",
            fromPane: store.selectedTab!.focusedPaneID
        )
        #expect(store.siteOverrides[0].hiddenSelectors == ["#promo"])
        #expect(store.pendingPickPattern == nil)
    }

    @Test("A pick made on another site is refused, not written into the override")
    func pickFromWrongHostIsRefused() async {
        let (store, _) = makeStore()
        await store.restore()
        store.setSiteOverride(SiteOverride(pattern: "example.com"))

        store.beginElementPick(forPattern: "example.com")
        store.panePickedSiteOverrideElement(
            selector: "#promo", host: "other.example",
            fromPane: store.selectedTab!.focusedPaneID
        )

        #expect(store.siteOverrides[0].hiddenSelectors.isEmpty)
        #expect(store.pendingPickPattern == nil)
    }

    @Test("Cancelling a pick clears the pending pattern")
    func cancelClearsPendingPick() async {
        let (store, _) = makeStore()
        await store.restore()
        store.setSiteOverride(SiteOverride(pattern: "example.com"))
        store.beginElementPick(forPattern: "example.com")
        #expect(store.pendingPickPattern == "example.com")

        store.paneDidCancelSiteOverridePick(fromPane: store.selectedTab!.focusedPaneID)
        #expect(store.pendingPickPattern == nil)
    }

    @Test("Removing the last override leaves the engine with nothing to inject")
    func removePushesEmpty() {
        let (store, engine) = makeStore()
        store.setSiteOverride(SiteOverride(pattern: "example.com", css: "a {}"))
        store.removeSiteOverride(pattern: "example.com")
        #expect(store.siteOverrides.isEmpty)
        #expect(engine.appliedSiteOverrides.isEmpty)
    }
}
