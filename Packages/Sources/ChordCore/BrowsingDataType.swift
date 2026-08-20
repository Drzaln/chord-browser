import Foundation

/// The categories of browsing data a "clear data" action can remove, as a
/// WebKit-free value type so the Store and UI can express intent without
/// importing WebKit. The engine maps each case onto the concrete
/// `WKWebsiteDataType*` constants (see `WebKitEngine`).
///
/// `history` is deliberately part of the same set even though it lives in the
/// app's own database, not WebKit's store — the "Clear browsing data" surface
/// treats it as one more checkbox, and the Store fans each selected type out to
/// the right subsystem.
public struct BrowsingDataType: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// On-disk and in-memory network/resource caches. Signing you out of nothing.
    public static let cache = BrowsingDataType(rawValue: 1 << 0)
    /// Cookies — clearing these signs you out of sites.
    public static let cookies = BrowsingDataType(rawValue: 1 << 1)
    /// localStorage, IndexedDB, service workers, and the other site storage.
    public static let siteStorage = BrowsingDataType(rawValue: 1 << 2)
    /// The app's own visit history (its database, not WebKit's store).
    public static let history = BrowsingDataType(rawValue: 1 << 3)

    /// Everything — the "clear all" default.
    public static let all: BrowsingDataType = [.cache, .cookies, .siteStorage, .history]

    /// The types that live in WebKit's `WKWebsiteDataStore` (everything but
    /// `history`, which the app clears from its own database).
    public var websiteDataTypes: BrowsingDataType {
        subtracting(.history)
    }
}
