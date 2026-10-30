import Foundation
import Testing

@testable import ChordStore

/// c1k.7: extensions wait for the first paint, or a timeout.
@Suite("Launch work waits for the first paint")
@MainActor
struct LaunchDeferralTests {

    @Test("A paint that never comes holds the work only until the timeout")
    func timeoutWins() async {
        let started = Date()
        await LaunchDeferral.first({ await withCheckedContinuation { _ in } }, orAfter: .milliseconds(200))
        let waited = Date().timeIntervalSince(started)
        #expect(waited >= 0.15 && waited < 1)
    }

    @Test("A paint that comes at once lets the work start at once")
    func paintWins() async {
        let started = Date()
        await LaunchDeferral.first({}, orAfter: .seconds(5))
        #expect(Date().timeIntervalSince(started) < 0.5)
    }
}
