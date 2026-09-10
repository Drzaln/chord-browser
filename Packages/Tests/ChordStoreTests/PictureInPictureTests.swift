import ChordCore
import ChordEngine
import ChordStore
import ChordTestSupport
import Foundation
import Testing

/// The View menu's Picture-in-Picture command (non-spec: user-requested) — the
/// store-side plumbing that routes the focused pane to the engine, toasts the
/// outcome, and keeps the Enter/Exit label honest.
@Suite("Picture in Picture")
@MainActor
struct PictureInPictureTests {

    private func makeStore() async -> (TabStore, FakeWebEngine, Tab) {
        let engine = FakeWebEngine()
        let tab = TabBuilder().url("https://a.example").build()
        let repository = FakeTabRepository(stored: [tab], spaces: [TabBuilder.defaultSpace()])
        let store = TabStore(
            engine: engine, repository: repository,
            spaceRepository: repository, clock: FixedClock()
        )
        await store.restore()
        store.select(tab.id)
        return (store, engine, tab)
    }

    @Test("Toggle routes the focused pane to the engine and toasts entering")
    func togglesFocusedPane() async {
        let (store, engine, tab) = await makeStore()
        engine.pictureInPictureResult = .entered

        await store.togglePictureInPicture(in: store.primaryWindow)

        #expect(engine.pictureInPictureToggles == [tab.focusedPaneID])
        #expect(store.isPictureInPictureActive(in: store.primaryWindow))
        #expect(store.primaryWindow.toast?.message == "Picture in Picture")
        #expect(store.primaryWindow.toast?.icon == "pip")
    }

    @Test("Toggle again exits and flips the label back")
    func exits() async {
        let (store, engine, tab) = await makeStore()
        engine.pictureInPictureResult = .entered
        await store.togglePictureInPicture(in: store.primaryWindow)
        #expect(store.isPictureInPictureActive(in: store.primaryWindow))

        engine.pictureInPictureResult = .exited
        await store.togglePictureInPicture(in: store.primaryWindow)

        #expect(engine.pictureInPictureToggles == [tab.focusedPaneID, tab.focusedPaneID])
        #expect(!store.isPictureInPictureActive(in: store.primaryWindow))
        #expect(store.primaryWindow.toast?.message == "Exited Picture in Picture")
    }

    @Test("No video leaves state alone and says so")
    func noVideo() async {
        let (store, engine, _) = await makeStore()
        engine.pictureInPictureResult = .noVideo

        await store.togglePictureInPicture(in: store.primaryWindow)

        #expect(!store.isPictureInPictureActive(in: store.primaryWindow))
        #expect(store.primaryWindow.toast?.message == "No video on this page")
    }

    @Test("The engine's watcher report keeps the label honest outside the command")
    func watcherReport() async {
        let (store, engine, tab) = await makeStore()

        engine.emitPictureInPictureChange(tab.focusedPaneID, active: true)
        #expect(store.isPictureInPictureActive(in: store.primaryWindow))

        engine.emitPictureInPictureChange(tab.focusedPaneID, active: false)
        #expect(!store.isPictureInPictureActive(in: store.primaryWindow))
    }

    @Test("Toggle with no selection does nothing")
    func noSelection() async {
        let engine = FakeWebEngine()
        let repository = FakeTabRepository(stored: [], spaces: [])
        let store = TabStore(
            engine: engine, repository: repository,
            spaceRepository: repository, clock: FixedClock()
        )

        await store.togglePictureInPicture(in: store.primaryWindow)

        #expect(engine.pictureInPictureToggles.isEmpty)
        #expect(!store.isPictureInPictureActive(in: store.primaryWindow))
    }
}