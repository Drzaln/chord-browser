import Foundation

/// A snapshot of an extension's toolbar action (M7, 7.5a).
///
/// WebKit-free, like everything the app sees of this subsystem: the live
/// `WKWebExtensionAction` stays inside the host, and the UI renders from these
/// plain values. The default (tab-independent) action is what a Space's
/// switcher-header button shows; the popup itself is opened through the host so
/// no `WK*` type escapes (ADR 011).
///
/// `icon` is pre-rendered PNG bytes rather than an `NSImage`, so `ChordUI`
/// stays free of any need to reach into the engine layer for image work.
public struct ExtensionActionSnapshot: Sendable, Equatable, Identifiable {
    public var id: String { "\(spaceID.uuidString):\(slug)" }
    public let slug: String
    public let spaceID: UUID
    /// The action's label (its tooltip / accessible name).
    public let label: String
    /// Badge text, empty when there is none.
    public let badgeText: String
    /// Whether clicking the action presents a popup (versus firing a click
    /// event). Drives whether the header button opens a popover.
    public let presentsPopup: Bool
    /// Whether the action is enabled for the current tab.
    public let enabled: Bool
    /// The action icon, pre-rendered to PNG, or `nil` when the extension
    /// supplies none.
    public let icon: Data?

    public init(
        slug: String,
        spaceID: UUID,
        label: String,
        badgeText: String,
        presentsPopup: Bool,
        enabled: Bool,
        icon: Data?
    ) {
        self.slug = slug
        self.spaceID = spaceID
        self.label = label
        self.badgeText = badgeText
        self.presentsPopup = presentsPopup
        self.enabled = enabled
        self.icon = icon
    }
}
