import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// Developer mode and full-page zoom (non-spec: user-requested) — the store
/// wiring that pushes each preference to the engine, and the gates that keep
/// the Web Inspector behind Developer Mode.
@Suite("Developer mode & zoom — store wiring")
@MainActor
struct DevModeZoomStoreTests {

    private func makeStore() -> (TabStore, FakeWebEngine) {
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine,
            repository: FakeTabRepository(stored: []),
            clock: FixedClock()
        )
        store.preferenceStore = InMemoryPreferenceStore()
        return (store, engine)
    }

    @Test("Developer mode is pushed to the engine and persists")
    func developerModeReachesEngine() {
        let (store, engine) = makeStore()
        #expect(store.developerMode == false)
        store.developerMode = true
        #expect(engine.developerMode == true)
        #expect(Preferences.loadDeveloperMode(store.preferenceStore) == true)
        store.developerMode = false
        #expect(engine.developerMode == false)
    }

    @Test("Page zoom steps reach the engine as a clamped factor")
    func pageZoomReachesEngine() {
        let (store, engine) = makeStore()
        store.zoomIn()
        #expect(engine.pageZoom == 1.1)
        #expect(store.pageZoom == 1.1)
        store.zoomOut()
        store.zoomOut()
        #expect(engine.pageZoom == 0.9)
        store.zoomReset()
        #expect(engine.pageZoom == 1.0)
        #expect(Preferences.loadPageZoom(store.preferenceStore) == 1.0)
    }

    @Test("Web Inspector is a no-op while developer mode is off")
    func inspectorGatedByDeveloperMode() {
        let (store, engine) = makeStore()
        let space = Space(id: UUID(), name: "S", sortIndex: 0)
        store.spaces.append(space)
        store.primaryWindow.activeSpaceID = space.id
        store.newTab(in: store.primaryWindow)
        let paneID = store.selectedTab(in: store.primaryWindow)!.focusedPaneID

        #expect(store.developerMode == false)
        store.showWebInspector(in: store.primaryWindow)
        #expect(engine.inspectorPanes.isEmpty)

        store.developerMode = true
        store.showWebInspector(in: store.primaryWindow)
        #expect(engine.inspectorPanes == [paneID])
    }

    @Test("DRM diagnostics flags the window's sheet")
    func drmDiagnosticsPresents() {
        let (store, window) = (makeStore().0, WindowState())
        store.showDRMDiagnostics(in: window)
        #expect(window.isDRMDiagnosticsPresented == true)
    }
}
