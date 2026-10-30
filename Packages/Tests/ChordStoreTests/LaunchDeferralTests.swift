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
        // Loose above: the full suite shares the main actor and can add a
        // second or more. Returning at all is what shows the timeout won.
        #expect(waited >= 0.15 && waited < 4)
    }

    @Test("A paint that comes at once lets the work start at once")
    func paintWins() async {
        let started = Date()
        await LaunchDeferral.first({}, orAfter: .seconds(30))
        // Well short of the timeout, with room for a busy main actor.
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
