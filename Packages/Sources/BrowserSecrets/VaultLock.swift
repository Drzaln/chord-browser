import Foundation
import LocalAuthentication

/// Decides *when* the vault is locked. Pure, so the policy can be tested without
/// a clock, a biometric sensor, or a UI.
///
/// Kept apart from the biometric call itself because the two fail in completely
/// different ways: this is arithmetic on timestamps, `BiometricAuthenticator` is
/// an OS prompt the user can refuse.
public struct VaultLockPolicy: Equatable, Sendable {
    /// How long the vault stays unlocked with no vault activity. Default 15
    /// minutes: long enough to log into several sites in one sitting, short
    /// enough that a walked-away-from Mac is not an open vault.
    public var idleTimeout: TimeInterval

    public init(idleTimeout: TimeInterval = 15 * 60) {
        self.idleTimeout = idleTimeout
    }

    /// Whether a vault unlocked at `unlockedAt` and last used at `lastActivity`
    /// should now be considered locked at `now`.
    public func isLocked(unlockedAt: Date?, lastActivity: Date?, now: Date) -> Bool {
        guard let unlockedAt else { return true }
        // Any vault use restarts the clock; without one, the unlock itself does.
        let since = max(unlockedAt, lastActivity ?? unlockedAt)
        return now.timeIntervalSince(since) >= idleTimeout
    }
}

/// Why an unlock attempt did not produce an unlocked vault. Distinguished
/// because the UI must say different things: a cancel is the user changing their
/// mind, an unavailable sensor means the gate cannot be offered at all.
public enum VaultUnlockFailure: Error, Equatable {
    /// The user cancelled, or failed to authenticate.
    case cancelled
    /// No biometry and no passcode configured — nothing to authenticate against.
    case unavailable
    /// Anything else `LocalAuthentication` reported.
    case failed(code: Int)
}

/// The biometric half of the gate.
///
/// A protocol, because every test that touches the vault would otherwise need a
/// finger. `BiometricAuthenticator` is the real one.
public protocol VaultAuthenticator: Sendable {
    /// Whether a gate can be offered at all on this machine.
    var isAvailable: Bool { get }
    /// Prompts, and returns normally only on success.
    func authenticate(reason: String) async throws(VaultUnlockFailure)
}

/// Touch ID (falling back to the device passcode) via `LocalAuthentication`.
///
/// **This is an app-level gate, not a cryptographic one**, and the distinction is
/// not academic: the Keychain items it guards are readable by anything running as
/// this user without ever calling here. It stops a person at your unlocked Mac
/// from reading passwords out of Chord; it does not stop code. The stronger form
/// — access-control items the Keychain itself refuses to release — was measured
/// unavailable on this signing setup (`-34018`); see `KeychainSecretStore`.
public struct BiometricAuthenticator: VaultAuthenticator {

    public init() {}

    public var isAvailable: Bool {
        // Owner authentication rather than biometrics-only: a Mac with no Touch
        // ID still has a password, and refusing to offer the gate there would be
        // worse than offering a slower one.
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    public func authenticate(reason: String) async throws(VaultUnlockFailure) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw .unavailable
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: reason
            )
            guard ok else { throw VaultUnlockFailure.cancelled }
        } catch let failure as VaultUnlockFailure {
            throw failure
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel, .authenticationFailed, .userFallback:
                throw .cancelled
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                throw .unavailable
            default:
                throw .failed(code: laError.code.rawValue)
            }
        } catch {
            throw .failed(code: (error as NSError).code)
        }
    }
}
