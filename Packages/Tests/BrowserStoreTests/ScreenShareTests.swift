import BrowserCore
import BrowserEngine
import BrowserTestSupport
import Foundation
import Testing

@testable import BrowserStore

/// Screen-share awareness and the "Stop sharing" control (non-spec:
/// user-requested). WebKit surfaces no display-capture state, so it is observed
/// in-page and mirrored onto the pane runtime; see `ScreenShareMonitor`.
@Suite("Screen sharing")
@MainActor
struct ScreenShareTests {

    private func makeStore(stored: [Tab]) async -> (TabStore, FakeWebEngine) {
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine,
            repository: FakeTabRepository(stored: stored),
            clock: FixedClock()
        )
        await store.restore()
        return (store, engine)
    }

    @Test("A snapshot reporting a share sets the pane's runtime flag")
    func snapshotDrivesRuntime() async {
        let (store, engine) = await makeStore(stored: [
            TabBuilder().url("https://meet.example").build()
        ])
        let tab = try! #require(store.visibleTabs.first)
        #expect(!store.runtime(for: tab.focusedPaneID).isScreenSharing)

        engine.emit(
            PaneSnapshot(url: URL(string: "https://meet.example"), isScreenSharing: true),
            for: tab.focusedPaneID
        )
        #expect(store.runtime(for: tab.focusedPaneID).isScreenSharing)

        engine.emit(
            PaneSnapshot(url: URL(string: "https://meet.example"), isScreenSharing: false),
            for: tab.focusedPaneID
        )
        #expect(!store.runtime(for: tab.focusedPaneID).isScreenSharing)
    }

    @Test("Stop sharing tells the engine to stop the focused pane's capture")
    func stopTellsEngine() async {
        let (store, engine) = await makeStore(stored: [
            TabBuilder().url("https://meet.example").build()
        ])
        let tab = try! #require(store.visibleTabs.first)

        store.stopScreenSharing()

        #expect(engine.stoppedScreenShares == [tab.focusedPaneID])
    }
}
