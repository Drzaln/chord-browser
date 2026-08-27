import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// The top-right action-confirmation toast (non-spec: user-requested) — the
/// per-window state that drives the overlay. The auto-dismiss timer is async,
/// so the deterministic part (present + replace + click action) is what is
/// asserted here.
@Suite("Window toast")
@MainActor
struct ToastTests {

    @Test("showToast presents a message and a new call replaces it")
    func presentsAndReplaces() {
        let window = WindowState(defaults: InMemoryPreferenceStore())
        #expect(window.toast == nil)

        window.showToast("Zoom 125%", icon: "plus")
        #expect(window.toast?.message == "Zoom 125%")
        let firstID = window.toast?.id

        window.showToast("Copied URL", icon: "link")
        #expect(window.toast?.message == "Copied URL")
        // A fresh id so the overlay re-animates rather than staling.
        #expect(window.toast?.id != firstID)
    }

    @Test("Open link in new tab shows a toast whose action selects that tab")
    func backgroundTabToastNavigates() {
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine,
            repository: FakeTabRepository(stored: []),
            clock: FixedClock()
        )
        store.preferenceStore = InMemoryPreferenceStore()
        let window = store.primaryWindow
        let space = Space(id: UUID(), name: "S", sortIndex: 0)
        store.spaces.append(space)
        window.activeSpaceID = space.id
        store.newTab(url: URL(string: "https://a.com")!, in: window)
        let original = window.selectedTabID

        store.paneRequestedBackgroundTab(
            url: URL(string: "https://b.com")!, fromPane: nil
        )

        let toast = window.toast
        #expect(toast?.message == "Opened in new tab")
        #expect(toast?.action != nil)

        // The toast's action dismisses itself and switches to the new tab.
        toast?.action?()
        #expect(window.toast == nil)
        let selected = window.selectedTabID
        #expect(selected != original)
        #expect(selected == store.tabs.last?.id)
        #expect(store.tabs.last?.focusedPane.url.absoluteString == "https://b.com")
    }
}
