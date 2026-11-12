import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// c1k.16: parked tabs are suspended only while no Chord window is on screen.
@Suite("Background tab suspension")
@MainActor
struct BackgroundTabPolicyTests {
    @Test func alwaysWinsWhateverTheWindowIsDoing() {
        for occluded in [true, false] {
            for showing in [true, false] {
                #expect(BackgroundTabPolicy.suspends(
                    always: true, whileHidden: false, isOccluded: occluded, isAboutToShow: showing
                ))
            }
        }
    }

    @Test func whileHiddenSuspendsOnlyWhenNothingIsOnScreen() {
        #expect(BackgroundTabPolicy.suspends(
            always: false, whileHidden: true, isOccluded: true, isAboutToShow: false
        ))
        #expect(!BackgroundTabPolicy.suspends(
            always: false, whileHidden: true, isOccluded: false, isAboutToShow: false
        ))
    }

    @Test func suspensionLiftsBeforeTheWindowIsBack() {
        #expect(!BackgroundTabPolicy.suspends(
            always: false, whileHidden: true, isOccluded: true, isAboutToShow: true
        ))
    }

    @Test func bothOffNeverSuspends() {
        #expect(!BackgroundTabPolicy.suspends(
            always: false, whileHidden: false, isOccluded: true, isAboutToShow: false
        ))
    }

    private func makeStore() -> (TabStore, FakeWebEngine) {
        let engine = FakeWebEngine()
        let store = TabStore(engine: engine, repository: FakeTabRepository(), clock: FixedClock())
        store.preferenceStore = InMemoryPreferenceStore()
        store.suspendsBackgroundTabs = false
        store.suspendsWhileHidden = true
        return (store, engine)
    }

    @Test func theEngineFollowsHideAndShow() {
        let (store, engine) = makeStore()
        #expect(!engine.suspendsBackgroundTabs)

        store.setOccluded(true)
        #expect(engine.suspendsBackgroundTabs)

        // Cmd-H then back: willUnhide arrives before the window is visible.
        store.prepareToShow()
        #expect(!engine.suspendsBackgroundTabs, "lifted before the window shows")
        store.setOccluded(false)
        #expect(!engine.suspendsBackgroundTabs)

        // The early signal does not stick: the next hide suspends again.
        store.setOccluded(true)
        #expect(engine.suspendsBackgroundTabs)
        // A minimized window coming back has no early signal.
        store.setOccluded(false)
        #expect(!engine.suspendsBackgroundTabs)
    }

    @Test func turningTheOptionOffWhileHiddenResumesTabs() {
        let (store, engine) = makeStore()
        store.setOccluded(true)
        #expect(engine.suspendsBackgroundTabs)
        store.suspendsWhileHidden = false
        #expect(!engine.suspendsBackgroundTabs)
    }
}
