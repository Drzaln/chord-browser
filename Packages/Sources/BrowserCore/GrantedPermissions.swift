import Foundation

/// The three kinds of thing an extension can be granted (M7, 7.5c), matching
/// WebKit's three permission-prompt delegate methods: a named API permission
/// (`tabs`, `cookies`, …), a specific URL, or a host match pattern
/// (`*://*.example.com/*`).
public enum GrantedPermissionKind: String, Sendable, Codable, CaseIterable {
    case permission
    case url
    case matchPattern
}

/// One granted permission for an extension in a Space (M7, 7.5c).
///
/// Identity is the whole tuple: the same extension can hold different grants in
/// different Spaces (extensions are per-Space, ADR 011). `value` is the raw
/// string — the permission name, the URL, or the match-pattern string — kept as
/// text so persistence needs no WebKit type. We persist these ourselves rather
/// than leaning on WebKit's own storage, and re-apply them on load.
public struct GrantedPermissionRecord: Sendable, Equatable, Hashable {
    public let spaceID: UUID
    public let slug: String
    public let kind: GrantedPermissionKind
    public let value: String

    public init(spaceID: UUID, slug: String, kind: GrantedPermissionKind, value: String) {
        self.spaceID = spaceID
        self.slug = slug
        self.kind = kind
        self.value = value
    }
}

/// Persists per-(Space, extension) permission grants. Defined here in
/// `BrowserCore` alongside the other repository protocols, WebKit-free, so the
/// Store can depend on it and `BrowserPersistence` can implement it (§3.6).
public protocol GrantedPermissionsRepository: Sendable {
    /// Every grant for an extension in a Space — read at load to re-apply them.
    func granted(slug: String, spaceID: UUID) async throws -> [GrantedPermissionRecord]
    /// Records grants. Idempotent: re-granting the same tuple is a no-op.
    func grant(_ records: [GrantedPermissionRecord]) async throws
    /// Drops every grant for an extension in a Space (e.g. on disable). A no-op
    /// if there were none.
    func revokeAll(slug: String, spaceID: UUID) async throws
}
