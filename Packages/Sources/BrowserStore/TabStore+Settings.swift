import BrowserCore
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
}
