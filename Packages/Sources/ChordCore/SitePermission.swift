import Foundation

/// A capability a page can ask a Space for — the granularity we remember a
/// decision at, so "allow camera but block notifications" is expressible.
/// Camera and microphone come from `getUserMedia`; notifications from the Web
/// Notifications shim (`NotificationBridge`).
public enum SitePermissionKind: String, Sendable, CaseIterable, Codable {
    case camera
    case microphone
    case notification
    case geolocation

    /// Sentence-case label for the prompt and settings ("Camera", "Notifications").
    public var label: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .notification: "Notifications"
        case .geolocation: "Location"
        }
    }
}

/// The remembered answer for one `(Space, origin, kind)` triple.
public enum SitePermissionDecision: String, Sendable, Codable {
    case granted
    case denied
}

/// A pending permission prompt, surfaced to the UI as plain values so no WebKit
/// type crosses the seam (mirrors the extension `PermissionRequest`).
///
/// The engine holds the matching WebKit reply implicitly via the awaiting
/// continuation in the store; the UI shows a grant/deny sheet and calls back
/// with the decision, which the store persists per-kind and returns.
/// All-or-nothing per request, matching how browsers present these.
public struct SitePermissionPrompt: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The security origin the decision is keyed on, e.g. `https://meet.google.com`.
    public let origin: String
    /// Just the host, for the sheet copy (`meet.google.com`).
    public let host: String
    /// The capabilities this request covers (camera/mic together, or notification).
    public let kinds: [SitePermissionKind]
    /// The pane that asked; the store resolves its Space so the decision is
    /// scoped to that Space (ADR 006/011), like cookies and extension grants.
    public let paneID: UUID?

    public init(
        id: UUID = UUID(),
        origin: String,
        host: String,
        kinds: [SitePermissionKind],
        paneID: UUID?
    ) {
        self.id = id
        self.origin = origin
        self.host = host
        self.kinds = kinds
        self.paneID = paneID
    }
}

/// One remembered decision, as flat values — what the settings panel lists and
/// lets the user revoke. Identity is the whole `(Space, origin, kind)` tuple.
public struct SitePermissionRecord: Sendable, Equatable, Identifiable {
    public let spaceID: UUID
    public let origin: String
    public let kind: SitePermissionKind
    public let decision: SitePermissionDecision

    public var id: String { "\(spaceID.uuidString)|\(origin)|\(kind.rawValue)" }

    public init(
        spaceID: UUID, origin: String, kind: SitePermissionKind, decision: SitePermissionDecision
    ) {
        self.spaceID = spaceID
        self.origin = origin
        self.kind = kind
        self.decision = decision
    }
}

/// Persists per-Space, per-origin camera/microphone/notification decisions so a
/// site is asked once, then remembered — normal browser behaviour, and the
/// replacement for the old blanket auto-grant (media) and global notification
/// permission. Scoped to a Space to match the isolation cookies, storage, and
/// extension grants already have (ADR 006, ADR 011). Defined here in
/// `ChordCore`, WebKit-free, so the Store can depend on it and
/// `ChordPersistence` can implement it.
public protocol SitePermissionsRepository: Sendable {
    /// Every remembered decision for an origin in a Space, read when a site
    /// requests a capability.
    func decisions(
        forOrigin origin: String, spaceID: UUID
    ) async throws -> [SitePermissionKind: SitePermissionDecision]
    /// Records (or overwrites) one Space/origin/kind decision.
    func setDecision(
        _ decision: SitePermissionDecision,
        forOrigin origin: String, spaceID: UUID, kind: SitePermissionKind
    ) async throws
    /// Every remembered decision, for the settings management list.
    func all() async throws -> [SitePermissionRecord]
    /// Forgets every kind decision for one origin in one Space (a "reset this
    /// site" action). The site is asked again next time.
    func revoke(origin: String, spaceID: UUID) async throws
    /// Forgets every remembered decision.
    func clearAll() async throws
}
