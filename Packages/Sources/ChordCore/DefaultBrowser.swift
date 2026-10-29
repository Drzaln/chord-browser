/// Whether Chord is the Mac's default web browser, and a way to ask macOS to
/// make it so. The seam keeps the Settings row testable without touching the
/// real system default; the live one wraps `NSWorkspace`.
@MainActor
public protocol DefaultBrowserControlling: AnyObject {
    /// True only when Chord opens both `http` and `https` links.
    var isDefault: Bool { get }
    /// Asks macOS to make Chord the default. macOS shows its own confirmation,
    /// which the user may decline, so callers re-read `isDefault` afterwards
    /// instead of trusting that this succeeded.
    func makeDefault() async throws
}
