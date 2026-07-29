import Foundation

/// A capture device a page can ask for via `getUserMedia` — the granularity we
/// remember a decision at, so "allow camera but not mic" is expressible.
public enum MediaDevice: String, Sendable, CaseIterable, Codable {
    case camera
    case microphone

    /// Sentence-case label for the permission sheet ("Camera", "Microphone").
    public var label: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        }
    }
}

/// The remembered answer for one `(Space, origin, device)` triple.
public enum MediaPermissionDecision: String, Sendable, Codable {
    case granted
    case denied
}

/// A pending camera/microphone prompt, surfaced to the UI as plain values so no
/// WebKit type crosses the seam (mirrors the extension `PermissionRequest`).
///
/// The engine holds the matching WebKit `decisionHandler` implicitly via the
/// awaiting continuation in the store; the UI shows a grant/deny sheet and calls
/// back with the decision, which the store persists per-device and returns.
/// All-or-nothing per request, matching how browsers present these.
public struct MediaPermissionRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The security origin the decision is keyed on, e.g. `https://meet.google.com`.
    public let origin: String
    /// Just the host, for the sheet copy (`meet.google.com`).
    public let host: String
    /// The devices this request covers (one or both). What the sheet lists.
    public let devices: [MediaDevice]
    /// The pane that asked; the store resolves its Space so the decision is
    /// scoped to that Space (ADR 006/011), like cookies and extension grants.
    public let paneID: UUID?

    public init(
        id: UUID = UUID(),
        origin: String,
        host: String,
        devices: [MediaDevice],
        paneID: UUID?
    ) {
        self.id = id
        self.origin = origin
        self.host = host
        self.devices = devices
        self.paneID = paneID
    }
}

/// One remembered decision, as flat values — what the settings panel lists and
/// lets the user revoke. Identity is the whole `(Space, origin, device)` tuple.
public struct SitePermissionRecord: Sendable, Equatable, Identifiable {
    public let spaceID: UUID
    public let origin: String
    public let device: MediaDevice
    public let decision: MediaPermissionDecision

    public var id: String { "\(spaceID.uuidString)|\(origin)|\(device.rawValue)" }

    public init(
        spaceID: UUID, origin: String, device: MediaDevice, decision: MediaPermissionDecision
    ) {
        self.spaceID = spaceID
        self.origin = origin
        self.device = device
        self.decision = decision
    }
}

/// Persists per-Space, per-origin camera/microphone decisions so a site is asked
/// once, then remembered — normal browser behaviour, and the replacement for the
/// old blanket auto-grant. Scoped to a Space to match the isolation cookies,
/// storage, and extension grants already have (ADR 006, ADR 011). Defined here
/// in `BrowserCore`, WebKit-free, so the Store can depend on it and
/// `BrowserPersistence` can implement it.
public protocol SitePermissionsRepository: Sendable {
    /// Every remembered decision for an origin in a Space, read when a site
    /// requests capture.
    func decisions(
        forOrigin origin: String, spaceID: UUID
    ) async throws -> [MediaDevice: MediaPermissionDecision]
    /// Records (or overwrites) one Space/origin/device decision.
    func setDecision(
        _ decision: MediaPermissionDecision,
        forOrigin origin: String, spaceID: UUID, device: MediaDevice
    ) async throws
    /// Every remembered decision, for the settings management list.
    func all() async throws -> [SitePermissionRecord]
    /// Forgets every device decision for one origin in one Space (a "reset this
    /// site" action). The site is asked again next time.
    func revoke(origin: String, spaceID: UUID) async throws
    /// Forgets every remembered decision.
    func clearAll() async throws
}
