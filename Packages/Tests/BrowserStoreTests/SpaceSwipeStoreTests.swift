import BrowserCore
import BrowserEngine
import BrowserStore
import BrowserTestSupport
import Foundation
import Testing

@Suite("Space swipe")
@MainActor
struct SpaceSwipeStoreTests {

    private func makeStore(spaces: [Space]) -> TabStore {
        let repository = FakeTabRepository(stored: [], spaces: spaces)
        return TabStore(
            engine: FakeWebEngine(),
            repository: repository,
            spaceRepository: repository,
            clock: FixedClock()
        )
    }

    private func threeSpaces() -> [Space] {
        [
            Space(name: "A", gradient: ["#000000", "#000000"], sortIndex: 0),
            Space(name: "B", gradient: ["#FFFFFF", "#FFFFFF"], sortIndex: 1),
            Space(name: "C", gradient: ["#FF0000", "#FF0000"], sortIndex: 2),
        ]
    }

    @Test("A committed forward swipe lands on the next Space")
    func commitForward() async {
        let spaces = threeSpaces()
        let store = makeStore(spaces: spaces)
        await store.restore()  // active = A (index 0)

        #expect(store.canSwipeSpace(direction: 1))
        store.beginSpaceSwipe()
        store.updateSpaceSwipe(offset: SpaceSwipe.fullSwipeDistance * 0.6)
        #expect(store.swipeShouldCommit())

        store.commitSpaceSwipe(direction: 1)
        #expect(store.activeSpace?.name == "B")
        #expect(store.spaceSwipeProgress == 0)
    }

    @Test("A short swipe does not commit")
    func shortSwipeCancels() async {
        let store = makeStore(spaces: threeSpaces())
        await store.restore()

        store.updateSpaceSwipe(offset: SpaceSwipe.fullSwipeDistance * 0.3)
        #expect(!store.swipeShouldCommit())
        #expect(store.activeSpace?.name == "A")
    }

    @Test("The first Space has no previous neighbour and rubber-bands")
    func rubberBandAtStart() async {
        let store = makeStore(spaces: threeSpaces())
        await store.restore()  // active = A, the first

        #expect(!store.canSwipeSpace(direction: -1))
        // A generous backward swipe past the start stays well short of a commit.
        store.updateSpaceSwipe(offset: -SpaceSwipe.fullSwipeDistance * 2)
        #expect(!store.swipeShouldCommit())
        #expect(abs(store.spaceSwipeProgress) < SpaceSwipe.commitThreshold)
    }

    @Test("The blended gradient tracks toward the neighbour")
    func blendedGradientTracksNeighbour() async {
        let store = makeStore(spaces: threeSpaces())
        await store.restore()  // A: black, neighbour B: white

        #expect(store.swipeBlendedGradient() == ["#000000", "#000000"])  // at rest

        store.updateSpaceSwipe(offset: SpaceSwipe.fullSwipeDistance)  // fully toward B
        #expect(store.swipeBlendedGradient() == ["#FFFFFF", "#FFFFFF"])
    }

    @Test("Progress resets after commit so the gradient shows the new Space")
    func gradientContinuousAcrossCommit() async {
        let store = makeStore(spaces: threeSpaces())
        await store.restore()

        // Drive fully to the neighbour, then commit: the pixels before and after
        // are the same white, so the switch reads as continuous.
        store.updateSpaceSwipe(offset: SpaceSwipe.fullSwipeDistance)
        let before = store.swipeBlendedGradient()
        store.commitSpaceSwipe(direction: 1)
        #expect(before == ["#FFFFFF", "#FFFFFF"])
        #expect(store.swipeBlendedGradient() == ["#FFFFFF", "#FFFFFF"])  // B at rest
    }
}
