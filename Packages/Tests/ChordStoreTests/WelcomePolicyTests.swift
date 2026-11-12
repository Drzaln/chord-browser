import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// gn0.6: the first-run welcome is offered once, to an empty profile only.
@Suite("First-run welcome")
@MainActor
struct WelcomePolicyTests {
    private func launch(
        spaces: [Space], prefs: InMemoryPreferenceStore, hasStore: Bool = true
    ) async -> TabStore {
        let repository = FakeTabRepository(stored: [], spaces: spaces)
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: repository,
            spaceRepository: hasStore ? repository : nil,
            clock: FixedClock()
        )
        store.preferenceStore = prefs
        await store.restore()
        return store
    }

    @Test func thePolicyNeedsBothAFreshProfileAndAnUnsetFlag() {
        #expect(WelcomePolicy.shouldShow(alreadyShown: false, isFreshProfile: true))
        #expect(!WelcomePolicy.shouldShow(alreadyShown: true, isFreshProfile: true))
        #expect(!WelcomePolicy.shouldShow(alreadyShown: false, isFreshProfile: false))
        #expect(!WelcomePolicy.shouldShow(alreadyShown: true, isFreshProfile: false))
    }

    @Test func aFreshProfileSeesItOnce() async {
        let prefs = InMemoryPreferenceStore()
        let first = await launch(spaces: [], prefs: prefs)
        #expect(first.primaryWindow.isWelcomePresented)
        #expect(Preferences.loadWelcomeShown(prefs))

        // Relaunch on the same preferences, still with nothing saved (the
        // user quit with the sheet up): it does not come back.
        let second = await launch(spaces: [], prefs: prefs)
        #expect(!second.primaryWindow.isWelcomePresented)
    }

    @Test func anExistingProfileNeverSeesIt() async {
        let prefs = InMemoryPreferenceStore()
        let store = await launch(spaces: [Space.makeDefault()], prefs: prefs)
        #expect(!store.primaryWindow.isWelcomePresented)
        // Settled, so emptying the profile later does not make it "new".
        #expect(Preferences.loadWelcomeShown(prefs))
        let later = await launch(spaces: [], prefs: prefs)
        #expect(!later.primaryWindow.isWelcomePresented)
    }

    @Test func aStoreWithNoPersistenceIsNotAFreshProfile() async {
        let prefs = InMemoryPreferenceStore()
        let store = await launch(spaces: [], prefs: prefs, hasStore: false)
        #expect(!store.primaryWindow.isWelcomePresented)
    }
}
