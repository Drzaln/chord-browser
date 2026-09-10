import Foundation
import Testing

@testable import ChordEngine

@Suite("Picture-in-Picture monitor")
struct PictureInPictureMonitorTests {

    @Test("A well-formed message parses to its active flag")
    func parsesActive() {
        #expect(PictureInPictureMonitor.isActive(from: ["active": true]) == true)
        #expect(PictureInPictureMonitor.isActive(from: ["active": false]) == false)
    }

    @Test("A malformed message parses to nil")
    func rejectsGarbage() {
        #expect(PictureInPictureMonitor.isActive(from: ["nope": 1]) == nil)
        #expect(PictureInPictureMonitor.isActive(from: "not a dict") == nil)
    }

    @Test("The toggle result maps onto the seam's outcome")
    func resultMapping() {
        #expect(PictureInPictureMonitor.result(from: ["action": "entered"]) == .entered)
        #expect(PictureInPictureMonitor.result(from: ["action": "exited"]) == .exited)
        #expect(PictureInPictureMonitor.result(from: ["action": "noVideo"]) == .noVideo)
        // Unknown action, no action key, and no body all fail closed.
        #expect(PictureInPictureMonitor.result(from: ["action": "bogus"]) == .noVideo)
        #expect(PictureInPictureMonitor.result(from: ["other": "x"]) == .unsupported)
        #expect(PictureInPictureMonitor.result(from: nil) == .unsupported)
    }
}