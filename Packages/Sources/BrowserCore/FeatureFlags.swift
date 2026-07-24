import Foundation

/// In-progress features, each defaulting off (BROWSER_SPEC 7.4).
///
/// This is what lets a half-built milestone sit on `main` without touching the
/// shipping browser: the wiring for the feature is present but inert until its
/// flag is turned on. Flags for shipped features get deleted — do not let this
/// accumulate a graveyard.
public struct FeatureFlags: Sendable, Equatable {
    /// M7. When off, no extension host is constructed and no
    /// `webExtensionController` is attached to any web view, so the engine
    /// builds exactly the configuration it did before M7. Default off while the
    /// host is being built across 7.1–7.6.
    public var extensionsEnabled: Bool

    /// Content blocking (§4.8). When off, no rule list is compiled or attached,
    /// so the engine builds exactly the web views it did before. Default off
    /// while the native blocker is built across C1–C4. Deleted when it ships.
    public var contentBlockingEnabled: Bool

    public init(extensionsEnabled: Bool = false, contentBlockingEnabled: Bool = false) {
        self.extensionsEnabled = extensionsEnabled
        self.contentBlockingEnabled = contentBlockingEnabled
    }

    /// The shipping configuration: everything in-progress is off.
    public static let `default` = FeatureFlags()
}
