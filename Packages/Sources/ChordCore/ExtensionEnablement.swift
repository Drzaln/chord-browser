import Foundation

/// Which extension is enabled in which Space (M7, 7.4).
///
/// The identity is the pair: an extension can be on in one Space and off in
/// another, because extensions are per-Space (ADR 011). `slug` is the install
/// directory name from `ExtensionInstaller`.
public struct ExtensionEnablementRecord: Sendable, Equatable, Hashable {
    public let spaceID: UUID
    public let slug: String

    public init(spaceID: UUID, slug: String) {
        self.spaceID = spaceID
        self.slug = slug
    }
}

/// Persists per-Space extension enablement. Presence of a record means enabled;
/// disabling removes it. Defined here in `ChordCore` alongside the other
/// repository protocols, WebKit-free, so the Store can depend on it and
/// `ChordPersistence` can implement it (§3.6).
public protocol ExtensionEnablementRepository: Sendable {
    /// Every enabled (Space, slug) pair — read once at launch to reload them.
    func allEnabled() async throws -> [ExtensionEnablementRecord]
    /// The slugs enabled in one Space.
    func enabledSlugs(spaceID: UUID) async throws -> [String]
    /// Turns an extension on or off in a Space. Idempotent.
    func setEnabled(_ enabled: Bool, slug: String, spaceID: UUID) async throws
}
