import Foundation
import Testing

@testable import BrowserSecrets

/// The lock *policy* — arithmetic, no sensor. The biometric half is a protocol
/// precisely so this can be tested without a finger.
@Suite("Vault lock policy")
struct VaultLockTests {

    private let policy = VaultLockPolicy(idleTimeout: 15 * 60)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("A vault that was never unlocked is locked")
    func neverUnlockedIsLocked() {
        #expect(policy.isLocked(unlockedAt: nil, lastActivity: nil, now: t0))
    }

    @Test("Just unlocked is open")
    func freshUnlockIsOpen() {
        #expect(
            policy.isLocked(unlockedAt: t0, lastActivity: nil, now: t0.addingTimeInterval(60))
                == false
        )
    }

    @Test("Idle past the timeout locks it")
    func idleLocks() {
        #expect(policy.isLocked(unlockedAt: t0, lastActivity: nil, now: t0.addingTimeInterval(901)))
    }

    @Test("Exactly at the timeout counts as locked")
    func boundaryIsLocked() {
        #expect(policy.isLocked(unlockedAt: t0, lastActivity: nil, now: t0.addingTimeInterval(900)))
    }

    @Test("Using the vault restarts the clock")
    func activityExtends() {
        // Unlocked at t0, used at +14min, checked at +20min: 6 minutes since use.
        #expect(
            policy.isLocked(
                unlockedAt: t0,
                lastActivity: t0.addingTimeInterval(14 * 60),
                now: t0.addingTimeInterval(20 * 60)
            ) == false
        )
    }

    @Test("Activity older than the unlock does not shorten the window")
    func staleActivityIsIgnored() {
        // A leftover timestamp from a previous session must not lock a vault that
        // was just unlocked.
        #expect(
            policy.isLocked(
                unlockedAt: t0,
                lastActivity: t0.addingTimeInterval(-3600),
                now: t0.addingTimeInterval(60)
            ) == false
        )
    }

    @Test("A zero timeout means every check finds it locked")
    func zeroTimeoutAlwaysLocked() {
        let immediate = VaultLockPolicy(idleTimeout: 0)
        #expect(immediate.isLocked(unlockedAt: t0, lastActivity: nil, now: t0))
    }
}
