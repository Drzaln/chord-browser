import BrowserCore
import Foundation

/// A pending permission prompt from an extension (M7, 7.5c), surfaced to the UI
/// as plain values so no WebKit type crosses the seam (ADR 011).
///
/// The host holds the matching WebKit completion handler keyed by `id`; the UI
/// shows a grant/deny sheet and calls back with the decision, which the host
/// turns into the WebKit allowed-set and (on grant) a persisted record. Grants
/// are all-or-nothing per request, which matches how browsers present these.
public struct PermissionRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let slug: String
    public let spaceID: UUID
    /// Which of the three prompt kinds this is (a named permission, a URL, or a
    /// host match pattern).
    public let kind: GrantedPermissionKind
    /// The requested values, as strings — permission names, URLs, or match
    /// patterns. What the sheet lists.
    public let items: [String]
    /// The extension's display name, for the sheet copy. May be `nil`.
    public let displayName: String?

    public init(
        id: UUID,
        slug: String,
        spaceID: UUID,
        kind: GrantedPermissionKind,
        items: [String],
        displayName: String?
    ) {
        self.id = id
        self.slug = slug
        self.spaceID = spaceID
        self.kind = kind
        self.items = items
        self.displayName = displayName
    }
}
