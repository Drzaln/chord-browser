import Foundation

/// A `new Notification(...)` a page asked to show, carried from the engine's
/// polyfill bridge to the app layer that posts it to macOS Notification Center.
///
/// WKWebView exposes no public Web Notifications hook, so `window.Notification`
/// is shimmed in the page and its calls are bridged natively (non-spec:
/// user-requested). This is the shape that crosses the seam — WebKit-free, so it
/// can live in Core and be handled by the app without importing WebKit.
public struct WebNotificationRequest: Sendable, Equatable {
    /// The page-side id of the `Notification` instance, echoed back on click so
    /// the shim can fire that instance's `onclick`.
    public let jsID: String
    public let title: String
    public let body: String
    /// The site's `icon` option, if any — resolved but not required.
    public let iconURL: URL?
    /// The `tag` option: a later notification with the same tag replaces the
    /// earlier one, matching the web spec's coalescing.
    public let tag: String?

    public init(jsID: String, title: String, body: String, iconURL: URL?, tag: String?) {
        self.jsID = jsID
        self.title = title
        self.body = body
        self.iconURL = iconURL
        self.tag = tag
    }
}
