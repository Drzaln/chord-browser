import AppKit
import ChordEngine
import ChordStore
import ChordTestSupport
import Testing

@testable import ChordUI

/// A window's event monitors are app-wide while installed, so one dropped
/// without `stop()` (a view shown twice without being hidden) must still take
/// its `NSEvent` monitor down with it.
@Suite("Event monitor lifetime", .serialized)
@MainActor
struct EventMonitorLifetimeTests {

    private func makeStore() async -> TabStore {
        let store = TabStore(
            engine: FakeWebEngine(), repository: FakeTabRepository(), clock: FixedClock()
        )
        await store.restore()
        return store
    }

    /// Takes a started monitor from `start`, drops it without stopping, and
    /// checks the app-wide count went up by one and back.
    private func expectRemovedOnRelease(_ start: () -> AnyObject) {
        let before = LocalEventMonitor.live
        var owner: AnyObject? = start()
        #expect(LocalEventMonitor.live == before + 1)
        _ = owner
        owner = nil
        #expect(LocalEventMonitor.live == before)
    }

    @Test("The Space swipe monitor goes with its owner")
    func spaceSwipe() async {
        let store = await makeStore()
        expectRemovedOnRelease {
            let monitor = SpaceSwipeMonitor(store: store, windowState: store.primaryWindow)
            monitor.start()
            return monitor
        }
    }

    @Test("The titlebar double-click monitor goes with its owner")
    func titlebar() {
        expectRemovedOnRelease {
            let monitor = TitlebarDoubleClickMonitor()
            monitor.start()
            return monitor
        }
    }

    @Test("The Ctrl-Tab monitor goes with its owner")
    func mruTabs() async {
        let store = await makeStore()
        expectRemovedOnRelease {
            let monitor = MRUTabKeyMonitor(store: store, windowState: store.primaryWindow)
            monitor.start()
            return monitor
        }
    }

    @Test("Stopping removes the monitor, and starting twice installs one")
    func stopAndRestart() {
        let before = LocalEventMonitor.live
        let monitor = TitlebarDoubleClickMonitor()
        monitor.start()
        monitor.start()
        #expect(LocalEventMonitor.live == before + 1)
        monitor.stop()
        #expect(LocalEventMonitor.live == before)
    }
}
