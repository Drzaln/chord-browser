import Foundation
import Testing

@testable import ChordEngine

@Suite("Screen-share monitor")
struct ScreenShareMonitorTests {

    @Test("A well-formed message parses to its sharing flag")
    func parsesSharing() {
        #expect(ScreenShareMonitor.isScreenSharing(from: ["sharing": true]) == true)
        #expect(ScreenShareMonitor.isScreenSharing(from: ["sharing": false]) == false)
    }

    @Test("A malformed message parses to nil")
    func rejectsGarbage() {
        #expect(ScreenShareMonitor.isScreenSharing(from: ["nope": 1]) == nil)
        #expect(ScreenShareMonitor.isScreenSharing(from: "not a dict") == nil)
    }
}
