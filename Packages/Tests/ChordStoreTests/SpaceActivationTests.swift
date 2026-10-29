import ChordCore
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// A Space's extensions load the first time a window shows it (c1k.2); the
/// store reports that moment, whichever path moved the window.
@Suite("Space activation")
@MainActor
struct SpaceActivationTests {

    private func makeStore() -> (TabStore, () -> [UUID]) {
        let repository = FakeTabRepository()
        let store = TabStore(
            engine: FakeWebEngine(), repository: repository,
            spaceRepository: repository, clock: FixedClock()
        )
        store.preferenceStore = InMemoryPreferenceStore()
        var activated: [UUID] = []
        store.onSpaceActivated = { activated.append($0.id) }
        return (store, { activated })
    }

    /// Lets the hook's task run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test("Restore reports nothing; afterRestore loads the Spaces on screen")
    func restoreIsQuiet() async {
        let (store, activated) = makeStore()
        var onScreenAtRestore: [UUID] = []
        store.afterRestore = { onScreenAtRestore = store.activeSpaces.map(\.id) }

        await store.restore()
        await settle()

        #expect(activated().isEmpty)
        #expect(onScreenAtRestore == [store.spaces[0].id])
    }

    @Test("Switching to a Space reports it, and switching back reports that one")
    func switchingReports() async {
        let (store, activated) = makeStore()
        await store.restore()
        let first = store.spaces[0].id
        store.addSpace(name: "Work")
        let work = store.spaces.first { $0.name == "Work" }!.id
        await settle()
        store.selectSpace(first)
        await settle()

        #expect(activated() == [work, first])
    }

    @Test("A window opened later reports the Space it opens on")
    func newWindowReports() async {
        let (store, activated) = makeStore()
        await store.restore()
        store.addSpace(name: "Work")
        let work = store.spaces.first { $0.name == "Work" }!
        await settle()
        let before = activated().count

        let window = WindowState(defaults: InMemoryPreferenceStore())
        window.activeSpaceID = work.id
        store.register(window)
        await settle()

        #expect(activated().count == before + 1)
        #expect(activated().last == work.id)
    }
}
