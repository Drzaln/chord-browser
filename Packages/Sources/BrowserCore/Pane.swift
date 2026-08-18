import Foundation

/// The unit that owns a web view.
///
/// A tab with a single pane is the normal case; split view (M5) is simply a tab
/// with more panes. Split view is deliberately *not* a separate type.
public struct Pane: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var url: URL
    public var title: String
    /// The user's own name for this tab, overriding the page title
    /// (non-spec: user-requested). Nil means "show the page title".
    public var customTitle: String?
    public var faviconData: Data?

    /// `WKWebView.interactionState`, used to revive an evicted or crashed pane
    /// without a full reload. Persisted out-of-line and loaded on demand.
    public var interactionState: Data?

    /// Split-view sizing. Sums to 1.0 across a tab's panes; always 1.0 in M1.
    public var widthFraction: Double

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String = "",
        customTitle: String? = nil,
        faviconData: Data? = nil,
        interactionState: Data? = nil,
        widthFraction: Double = 1.0
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.customTitle = customTitle
        self.faviconData = faviconData
        self.interactionState = interactionState
        self.widthFraction = widthFraction
    }

    /// Title if the page supplied one, otherwise something short and stable to
    /// show in the sidebar. Precomputed at mutation time, never in a view body.
    public var displayTitle: String {
        if let customTitle {
            let name = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        if !title.isEmpty { return title }
        if let host = url.host() { return host }
        return url.absoluteString
    }
}
