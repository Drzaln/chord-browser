import BrowserCore
import BrowserEngine
import BrowserTestSupport
import Foundation
import Testing

@testable import BrowserStore

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
}
