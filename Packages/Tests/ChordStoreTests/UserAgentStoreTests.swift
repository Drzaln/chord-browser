import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// The User-Agent preference reaches the engine (non-spec: user-requested).
@Suite("User agent — store wiring")
@MainActor
struct UserAgentStoreTests {

    private func makeStore() -> (TabStore, FakeWebEngine) {
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine,
            repository: FakeTabRepository(stored: []),
            clock: FixedClock()
        )
        return (store, engine)
    }

    @Test("The persisted UA is pushed to the engine at construction")
    func appliesAtInit() {
        let (_, engine) = makeStore()
        // Default preference resolves to nil, but it is still applied once so the
        // engine starts in a known state.
        #expect(engine.customUserAgentSetCount >= 1)
        #expect(engine.customUserAgent == nil)
    }

    @Test("Changing the UA preference tells the engine the resolved string")
    func changePushesToEngine() {
        let (store, engine) = makeStore()
        store.userAgent = .chrome
        #expect(engine.customUserAgent == UserAgentPreference.chrome.resolvedUserAgent)
        #expect(engine.customUserAgent?.contains("Chrome/") == true)

        store.userAgent = .default
        #expect(engine.customUserAgent == nil)
    }

    @Test("A per-domain rule is normalised, replaces its predecessor, and reaches the engine")
    func perDomainRulesReachTheEngine() {
        let (store, engine) = makeStore()
        store.preferenceStore = InMemoryPreferenceStore()
        // Start from nothing regardless of what is on this machine: the property
        // initialiser reads `UserDefaults.standard` before the line above can
        // redirect it, and an ambient rule left by anything else would otherwise
        // decide this test's outcome. That is not hypothetical — an e2e test
        // wrote one, and this assertion is where it surfaced.
        store.userAgentOverrides = []

        #expect(
            store.setUserAgentOverride(domain: "https://MEET.google.com/abc", preference: .chrome)
        )
        #expect(store.userAgentOverrides.map(\.domain) == ["meet.google.com"])
        #expect(engine.userAgentOverrides.map(\.domain) == ["meet.google.com"])

        // The same domain again replaces rather than duplicates.
        #expect(store.setUserAgentOverride(domain: "meet.google.com", preference: .default))
        #expect(store.userAgentOverrides.count == 1)
        #expect(store.userAgentOverrides.first?.preference == .default)

        // Junk is refused rather than stored as a rule that matches nothing.
        #expect(store.setUserAgentOverride(domain: "chrome", preference: .chrome) == false)
        #expect(store.userAgentOverrides.count == 1)

        store.removeUserAgentOverride(domain: "meet.google.com")
        #expect(store.userAgentOverrides.isEmpty)
        #expect(engine.userAgentOverrides.isEmpty)
    }
}
