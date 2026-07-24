import Foundation

/// An extension that is loaded into a Space's controller right now.
///
/// WebKit-free, like everything the app sees of this subsystem: the underlying
/// `WKWebExtensionContext` stays inside the host. `slug` ties back to the
/// `InstalledExtension` it came from; `spaceID` says which Space's controller it
/// is running in (extensions are per-Space, ADR 011).
public struct LoadedExtension: Sendable, Equatable, Identifiable {
    public var id: String { "\(spaceID.uuidString):\(slug)" }
    public let slug: String
    public let spaceID: UUID
    public let displayName: String?
    public let manifestVersion: Double

    public init(slug: String, spaceID: UUID, displayName: String?, manifestVersion: Double) {
        self.slug = slug
        self.spaceID = spaceID
        self.displayName = displayName
        self.manifestVersion = manifestVersion
    }
}

public enum ExtensionLoadError: Error, CustomStringConvertible {
    /// We accept MV3 only (BROWSER_SPEC 4.7). WebKit itself will load MV2, so
    /// this is our policy, enforced here at load — the earliest point the
    /// manifest has actually been parsed.
    case unsupportedManifestVersion(Double)
    /// `WKWebExtension` could not read the bundle (bad or missing manifest,
    /// unreadable archive). Carries WebKit's own error.
    case unreadableBundle(any Error)
    /// `WKWebExtensionController.load` refused the context. Carries WebKit's
    /// error.
    case controllerRejected(any Error)

    public var description: String {
        switch self {
        case .unsupportedManifestVersion(let v):
            "manifest version \(v) is not supported — this browser loads MV3 only"
        case .unreadableBundle(let e):
            "could not read the extension bundle: \(e)"
        case .controllerRejected(let e):
            "the extension controller refused to load the context: \(e)"
        }
    }
}
