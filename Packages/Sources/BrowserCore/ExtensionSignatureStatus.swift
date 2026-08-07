import Foundation

/// Whether an extension bundle's identity can be trusted, computed at install
/// and surfaced in the UI so an untrusted bundle is never silently enabled.
///
/// `.trusted` and `.verified` both mean the bundle's signature validates against
/// the public key it carries; `.trusted` additionally means that key is one the
/// app pins as a known signer. Everything else is a warning state. The raw value
/// is persisted next to the installed bundle so the verdict survives a relaunch.
public enum ExtensionSignatureStatus: String, Sendable, Equatable, Codable, CaseIterable {
    /// The signature validates AND the embedded key is one the app pins.
    case trusted
    /// The signature validates against the embedded key, but that key is not
    /// pinned — "signed by someone, not anyone we vouch for".
    case verified
    /// A signature is present but fails to validate — tampered or repacked.
    case tampered
    /// No signature present (plain `.xpi`/`.zip`). No cryptographic
    /// attribution; only the file's own word for what it is.
    case unsigned
    /// The header could not be parsed well enough to check.
    case unsupported

    /// Whether this verdict warrants trusting the bundle without a warning.
    public var isTrusted: Bool {
        switch self {
        case .trusted, .verified: return true
        case .tampered, .unsigned, .unsupported: return false
        }
    }
}
