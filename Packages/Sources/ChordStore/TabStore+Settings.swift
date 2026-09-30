import ChordCore
import ChordEngine
import Foundation

/// The settings surface's data actions (M8, non-spec: user-requested). The Store
/// is the WebKit-free coordination point that already holds both the engine and
/// the history repository, so "clear browsing data" fans each selected type out
/// to the right subsystem from here.
extension TabStore {
    /// Clears the selected data types. Website data (cache, cookies, site
    /// storage) is cleared from **every Space's** store so it is a true global
    /// clear; history is cleared from the app's own database. Irreversible — the
    /// caller confirms first.
    public func clearBrowsingData(_ types: BrowsingDataType) async {
        let websiteTypes = types.websiteDataTypes
        if !websiteTypes.isEmpty {
            await engine.clearWebsiteData(websiteTypes, forSpaces: spaces)
        }
        if types.contains(.history) {
            do {
                try await historyRepository?.deleteAllHistory()
            } catch {
                Log.store.error("clear history failed: \(String(describing: error))")
            }
        }
    }

    // MARK: - Per-site cookies (non-spec: user-requested)

    /// The site the focused window is showing, if any — what the Privacy & Data
    /// cookie view inspects by default.
    public var activeSiteURL: URL? {
        guard let tabID = focusedWindow.selectedTabID,
            let tab = tabs.first(where: { $0.id == tabID })
        else { return nil }
        return runtime(for: tab.focusedPaneID).currentURL
    }

    /// Cookies the Space's store holds for a URL. Empty before macOS 27 (no
    /// `cookies(for:)`), and for a Space that no longer exists.
    public func siteCookies(for url: URL, inSpace spaceID: UUID) async -> [SiteCookie] {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return [] }
        return await engine.cookies(for: url, in: space)
    }

    /// Deletes the Space's cookies for a URL. Scoped to the site, so the user can
    /// sign out of one site without clearing the whole Space.
    public func clearSiteCookies(for url: URL, inSpace spaceID: UUID) async {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return }
        await engine.clearCookies(for: url, in: space)
    }
}
