import BrowserCore
import Testing

@Suite("Space swipe maths")
struct SpaceSwipeTests {

    @Test("A full swipe distance is progress 1.0")
    func fullDistanceIsUnitProgress() {
        #expect(SpaceSwipe.progress(forOffset: SpaceSwipe.fullSwipeDistance) == 1.0)
        #expect(SpaceSwipe.progress(forOffset: -SpaceSwipe.fullSwipeDistance) == -1.0)
        #expect(SpaceSwipe.progress(forOffset: 0) == 0)
    }

    @Test("Rubber-band resists past the end, never reaching 1")
    func rubberBandDiminishes() {
        #expect(SpaceSwipe.rubberBand(0) == 0)
        // A swipe that would be twice the full distance is held well short of a
        // commit, so an end genuinely feels like a wall.
        #expect(SpaceSwipe.rubberBand(2) < SpaceSwipe.commitThreshold)
        // Monotonic and bounded below 1.
        #expect(SpaceSwipe.rubberBand(1) < SpaceSwipe.rubberBand(5))
        #expect(SpaceSwipe.rubberBand(1000) < 1)
    }

    @Test("Blend at the ends returns each endpoint")
    func blendEndpoints() {
        let a: [ColorHex] = ["#000000", "#000000"]
        let b: [ColorHex] = ["#FFFFFF", "#FFFFFF"]
        #expect(SpaceSwipe.blend(a, b, t: 0).map(\.value) == a.map(\.value))
        #expect(SpaceSwipe.blend(a, b, t: 1).map(\.value) == b.map(\.value))
    }

    @Test("Blend midpoint is the halfway colour")
    func blendMidpoint() {
        let mid = SpaceSwipe.blend(["#000000"], ["#FFFFFF"], t: 0.5)
        #expect(mid == ["#808080"])  // 127.5 rounds to 128
    }

    @Test("Unequal stop counts pad rather than pop")
    func blendUnequalLengths() {
        // Two stops blended toward three keeps three stops throughout, so the
        // gradient never changes its stop count partway and jumps.
        let blended = SpaceSwipe.blend(
            ["#000000", "#000000"], ["#FFFFFF", "#FFFFFF", "#FFFFFF"], t: 1
        )
        #expect(blended.count == 3)
        #expect(blended.allSatisfy { $0 == "#FFFFFF" })
    }

    @Test("Colour lerp is clamped and rounds")
    func colourLerp() {
        #expect(ColorHex.lerp("#000000", "#FFFFFF", t: -1) == "#000000")
        #expect(ColorHex.lerp("#000000", "#FFFFFF", t: 2) == "#FFFFFF")
        // A malformed endpoint degrades to the start colour rather than crashing.
        #expect(ColorHex.lerp("nonsense", "#FFFFFF", t: 0.5) == "nonsense")
    }
}
