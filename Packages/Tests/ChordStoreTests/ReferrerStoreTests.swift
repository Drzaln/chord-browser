import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// The referrer preference reaches the engine (non-spec: user-requested).
@Suite("Referrer — store wiring")
@MainActor
struct ReferrerStoreTests {

    private func makeStore() -> (TabStore, FakeWebEngine) {
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine,
            repository: FakeTabRepository(stored: []),
            clock: FixedClock()
        )
        // Preferences go to memory, never the developer's real defaults — the
        // same guard the UA tests need, and the reason this suite cannot leak a
        // referrer rule into the next run.
        store.preferenceStore = InMemoryPreferenceStore()
        return (store, engine)
    }

    @Test("The persisted policy is pushed to the engine at construction")
    func appliesAtInit() {
        let (store, engine) = makeStore()
        // The property initialiser reads `UserDefaults.standard` before
        // `makeStore` can redirect it, so the value is whatever the machine has —
        // but construction must still push *that* value, or the engine would
        // start on the default with the user's choice ignored.
        #expect(engine.referrerPolicySetCount >= 1)
        #expect(engine.referrerPolicy == store.referrerPolicy)
    }

    @Test("Changing the global policy tells the engine")
    func changePushesToEngine() {
        let (store, engine) = makeStore()
        store.referrerPolicy = .strip
        #expect(engine.referrerPolicy == .strip)

        store.referrerPolicy = .custom("https://ref.example/")
        #expect(engine.referrerPolicy == .custom("https://ref.example/"))
    }

    @Test("A per-domain rule is normalised, replaces its predecessor, and reaches the engine")
    func perDomainRulesReachTheEngine() {
        let (store, engine) = makeStore()
        store.referrerOverrides = []

        #expect(store.setReferrerOverride(domain: "https://Bank.com/login", policy: .default))
        #expect(store.referrerOverrides.map(\.domain) == ["bank.com"])
        #expect(engine.referrerOverrides.map(\.domain) == ["bank.com"])

        // The same domain again replaces rather than duplicates.
        #expect(store.setReferrerOverride(domain: "bank.com", policy: .strip))
        #expect(store.referrerOverrides.count == 1)
        #expect(store.referrerOverrides.first?.policy == .strip)

        // Junk is refused rather than stored as a rule that matches nothing.
        #expect(store.setReferrerOverride(domain: "strip", policy: .strip) == false)
        #expect(store.referrerOverrides.count == 1)

        store.removeReferrerOverride(domain: "bank.com")
        #expect(store.referrerOverrides.isEmpty)
        #expect(engine.referrerOverrides.isEmpty)
    }
}
