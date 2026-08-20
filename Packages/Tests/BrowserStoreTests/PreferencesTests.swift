import BrowserCore
import BrowserEngine
import BrowserTestSupport
import Foundation
import Testing

@testable import BrowserStore

/// The search-engine and new-tab preferences (non-spec: user-requested). They
/// steer what a blank tab opens to and where the command bar's search fallback
/// points.
@Suite("Search engine & new-tab preferences")
@MainActor
struct PreferencesTests {

    private func makeStore() async -> TabStore {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: []),
            clock: FixedClock()
        )
        await store.restore()
        return store
    }

    @Test("A blank new-tab behaviour opens about:blank")
    func blankNewTab() async {
        let store = await makeStore()
        store.newTabBehavior = .blank
        store.newTab()

        #expect(store.selectedTab?.focusedPane.url == NewTabBehavior.blankURL)
    }

    @Test("A custom new-tab behaviour opens the chosen URL")
    func customNewTab() async {
        let store = await makeStore()
        let home = URL(string: "https://start.example/home")!
        store.newTabBehavior = .custom(home)
        store.newTab()

        #expect(store.selectedTab?.focusedPane.url == home)
    }

    @Test("The search-engine home is used when the behaviour is searchEngine")
    func searchEngineHomeNewTab() async {
        let store = await makeStore()
        store.searchEngine = .duckDuckGo
        store.newTabBehavior = .searchEngine
        store.newTab()

        #expect(store.selectedTab?.focusedPane.url == SearchEngine.duckDuckGo.homepageURL)
    }

    @Test("The command bar's search fallback uses the configured engine")
    func searchFallbackHonoursEngine() async {
        let store = await makeStore()
        store.searchEngine = .duckDuckGo

        let results = store.suggestions(for: "swift concurrency")
        let search = results.first { if case .search = $0.kind { return true } else { return false } }
        guard case .search(_, let url)? = search?.kind else {
            Issue.record("expected a search suggestion")
            return
        }
        #expect(url.absoluteString.hasPrefix("https://duckduckgo.com/?q="))
        #expect(url.absoluteString.contains("swift%20concurrency"))
    }

    @Test("An explicit URL still overrides the new-tab behaviour")
    func explicitURLWins() async {
        let store = await makeStore()
        store.newTabBehavior = .blank
        let explicit = URL(string: "https://example.com")!
        store.newTab(url: explicit)

        #expect(store.selectedTab?.focusedPane.url == explicit)
    }

    @Test("The Little Chord panel size starts unset and round-trips a resize")
    func littleChordPanelSizeRoundTrips() async {
        let store = await makeStore()
        store.preferenceStore = InMemoryPreferenceStore()

        // Unset → the controller falls back to the panel's default size.
        #expect(store.littleChordPanelSize == nil)

        store.littleChordPanelSize = CGSize(width: 800, height: 640)
        #expect(store.littleChordPanelSize == CGSize(width: 800, height: 640))
    }

    @Test("Swipe-to-close defaults on and disabling reaches the engine")
    func swipeToCloseDefaultsOnAndPushes() async {
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine, repository: FakeTabRepository(stored: []), clock: FixedClock()
        )

        #expect(engine.swipeToCloseEnabled, "a fresh profile has the feature on")

        store.preferenceStore = InMemoryPreferenceStore()
        store.swipeToCloseEnabled = false

        #expect(!engine.swipeToCloseEnabled, "disabling reaches the engine")
    }

    @Test("Disabling swipe-to-close persists")
    func swipeToClosePersists() async {
        let store = await makeStore()
        let defaults = InMemoryPreferenceStore()
        store.preferenceStore = defaults

        store.swipeToCloseEnabled = false

        #expect(defaults.object(forKey: "prefs.swipeToCloseEnabled") as? Bool == false)
    }
}
