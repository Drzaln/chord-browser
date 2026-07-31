import BrowserCore
import BrowserSecrets
import Foundation

/// Why the vault could not be unlocked, in the terms the UI has to explain.
public enum VaultUnlockOutcome: Equatable, Sendable {
    /// The vault is unlocked — either it already was, or authentication passed.
    case unlocked
    /// The user cancelled or failed authentication. Nothing was filled.
    case refused
    /// There is nothing to authenticate against on this machine: no biometry and
    /// no device passcode. See `TabStore.unlockVault()` for why this does not
    /// leave the vault permanently unusable.
    case unavailable
}

extension TabStore {

    // MARK: - Lock state (V7)

    /// The idle policy in force, built from the user's preference.
    var vaultLockPolicy: VaultLockPolicy? {
        vaultLockTimeout.seconds.map { VaultLockPolicy(idleTimeout: $0) }
    }

    /// Re-evaluates `isVaultLocked` against the clock.
    ///
    /// Cheap and idempotent, so callers may run it freely: it is arithmetic on
    /// two dates. Assigning the same value back to an `@Observable` property does
    /// not invalidate a view, so an unchanged answer costs nothing on screen.
    public func refreshVaultLock() {
        guard let policy = vaultLockPolicy else {
            // The idle clock is off: locked only until something unlocks it, and
            // then until sleep, screen lock, or Lock Now.
            isVaultLocked = vaultUnlockedAt == nil
            return
        }
        isVaultLocked = policy.isLocked(
            unlockedAt: vaultUnlockedAt, lastActivity: vaultLastActivity, now: clock.now
        )
    }

    /// Locks the vault now.
    ///
    /// Called by Lock Now in Settings and, from the app layer, on sleep, screen
    /// lock, and fast-user-switch. Nothing is cleared but the unlock — the
    /// credentials themselves live in the Keychain and were never held here.
    public func lockVault() {
        vaultUnlockedAt = nil
        vaultLastActivity = nil
        isVaultLocked = true
    }

    /// Records that the vault was just used, restarting the idle clock.
    func noteVaultActivity() {
        vaultLastActivity = clock.now
        refreshVaultLock()
    }

    /// Unlocks the vault, prompting for Touch ID (or the device passcode) if it
    /// is currently locked.
    ///
    /// Returns `.unlocked` without prompting when the vault is already unlocked
    /// — re-authenticating for every fill inside one sitting is the behaviour
    /// that makes people turn a password manager off, and the idle window is the
    /// thing that bounds it.
    ///
    /// **`.unavailable` is not a locked vault.** With no biometry and no device
    /// passcode there is nothing to authenticate against, so a gate here would
    /// only ever stop the user — never an attacker, who by then has the same
    /// access to the machine that the gate is asking about. Callers that fill
    /// proceed; `revealCredential` still refuses, because that one puts a
    /// password on screen as text.
    @discardableResult
    public func unlockVault() async -> VaultUnlockOutcome {
        refreshVaultLock()
        if !isVaultLocked { return .unlocked }

        guard let authenticator, authenticator.isAvailable else { return .unavailable }
        do {
            try await authenticator.authenticate(reason: "unlock your saved passwords")
        } catch .unavailable {
            return .unavailable
        } catch {
            return .refused
        }

        vaultUnlockedAt = clock.now
        vaultLastActivity = nil
        isVaultLocked = false
        return .unlocked
    }
}
