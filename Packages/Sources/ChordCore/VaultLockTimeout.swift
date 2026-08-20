import Foundation

/// How long the password vault stays unlocked with no vault activity (V7 —
/// `docs/design/password-vault.md`).
///
/// A preference rather than a constant because the right answer depends on where
/// the Mac lives: 1 minute on a laptop taken to cafés, an hour on a desk nobody
/// else reaches. `.never` is offered honestly rather than hidden — it does not
/// mean "never lock", it means the idle clock is off and only sleep and screen
/// lock still lock the vault. Those two are not configurable, because they are
/// the cases where the user has demonstrably walked away.
public enum VaultLockTimeout: Codable, Hashable, Sendable {
    /// No idle lock. Sleep and screen lock still lock the vault.
    case never
    case after(TimeInterval)

    /// 15 minutes: long enough to sign into several sites in one sitting, short
    /// enough that a walked-away-from Mac is not an open vault.
    public static let `default` = VaultLockTimeout.after(15 * 60)

    /// The idle window in seconds, or nil when the idle clock is off.
    public var seconds: TimeInterval? {
        if case .after(let value) = self { return value }
        return nil
    }

    /// The presets offered in Settings, in menu order.
    public static let presets: [VaultLockTimeout] = [
        .after(60),
        .after(5 * 60),
        .after(15 * 60),
        .after(60 * 60),
        .never,
    ]

    /// A short label for the picker.
    public var displayName: String {
        switch self {
        case .never:
            return "Only on sleep or screen lock"
        case .after(let value):
            let minutes = Int((value / 60).rounded())
            if minutes % 60 == 0 {
                let hours = minutes / 60
                return hours == 1 ? "After 1 hour idle" : "After \(hours) hours idle"
            }
            return minutes == 1 ? "After 1 minute idle" : "After \(minutes) minutes idle"
        }
    }
}
