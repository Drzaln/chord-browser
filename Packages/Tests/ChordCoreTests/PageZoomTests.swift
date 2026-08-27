import ChordCore
import Testing

/// The full-page zoom ladder (non-spec: user-requested). Pure arithmetic, so it
/// is unit-tested here rather than against a web view.
@Suite("Page zoom ladder")
struct PageZoomTests {

    @Test("Zoom in steps up to the next rung")
    func zoomIn() {
        #expect(PageZoom.zoomIn(1.0) == 1.1)
        #expect(PageZoom.zoomIn(0.9) == 1.0)
    }

    @Test("Zoom out steps down to the previous rung")
    func zoomOut() {
        #expect(PageZoom.zoomOut(1.0) == 0.9)
        #expect(PageZoom.zoomOut(1.1) == 1.0)
    }

    @Test("Zooming at the ends clamps, never extrapolates")
    func clampsAtEnds() {
        #expect(PageZoom.zoomIn(5.0) == 5.0)
        #expect(PageZoom.zoomOut(0.25) == 0.25)
    }

    @Test("Off-ladder values clamp onto the range, not to a bogus factor")
    func clampsOffLadder() {
        #expect(PageZoom.clamped(0.0) == 0.25)
        #expect(PageZoom.clamped(9.0) == 5.0)
        #expect(PageZoom.clamped(1.0) == 1.0)
    }

    @Test("Actual size resets to 100%")
    func reset() {
        #expect(PageZoom.defaultFactor == 1.0)
    }
}
