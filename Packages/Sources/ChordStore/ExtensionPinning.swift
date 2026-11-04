import Foundation
import Observation

/// Which extensions keep a button in the address field (non-spec:
/// user-requested, 21n). Chrome's "pin to toolbar": a pinned extension's
/// action shows at the field's end; an unpinned one still runs everywhere and
/// is reached from the Manage Extensions panel. Without it, ten extensions
/// took ~285 pt of a 240 pt sidebar and left the address no room at all.
///
/// Per extension, not per Space: where its button sits is about the window's
/// chrome, and an extension is the same one in every Space.
///
/// Stored as the set of *pinned* slugs, so a slug nobody has decided about is
/// unpinned — a new install never grows the bar by surprise. The first run with
/// this in place pins everything already installed, so updating keeps the
/// address field looking exactly as it did.
@MainActor
@Observable
public final class ExtensionPinning {
    static let key = "extensions.pinned"

    @ObservationIgnored private let preferences: any PreferenceStore
    public private(set) var pinnedSlugs: Set<String>

    /// - Parameter installedSlugs: read only when nothing was ever stored, to
    ///   pin what was installed before pinning existed.
    public init(preferences: any PreferenceStore, installedSlugs: () -> [String]) {
        self.preferences = preferences
        if let stored = preferences.object(forKey: Self.key) as? [String] {
            pinnedSlugs = Set(stored)
        } else {
            pinnedSlugs = Set(installedSlugs())
            preferences.set(pinnedSlugs.sorted(), forKey: Self.key)
        }
    }

    public func isPinned(_ slug: String) -> Bool { pinnedSlugs.contains(slug) }

    public func setPinned(_ pinned: Bool, slug: String) {
        guard pinned != isPinned(slug) else { return }
        if pinned { pinnedSlugs.insert(slug) } else { pinnedSlugs.remove(slug) }
        preferences.set(pinnedSlugs.sorted(), forKey: Self.key)
    }

    /// An uninstalled extension leaves no pin behind, so installing it again
    /// starts unpinned like any new one.
    public func forget(_ slug: String) { setPinned(false, slug: slug) }
}
