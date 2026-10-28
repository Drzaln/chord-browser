import ChordCore
import ChordEngine
import ChordExtensions
import Foundation

/// The app side of a Chrome Web Store page's "Add to Chord" button.
///
/// The id is checked against the focused tab's own address before anything is
/// downloaded, so a page cannot ask Chord to install an unrelated extension.
@MainActor
final class StoreInstallRelay: ChromeStoreRelayDelegate {
    private weak var store: TabStore?
    private let extensions: ExtensionsService

    init(store: TabStore, extensions: ExtensionsService) {
        self.store = store
        self.extensions = extensions
    }

    func installFromStorePage(id: String) {
        guard let store, let tab = store.selectedTab(in: store.focusedWindow),
              Crx.storeID(of: tab.focusedPane.url) == id,
              let space = store.activeSpace(in: store.focusedWindow)
        else { return }
        let window = store.focusedWindow
        window.showToast("Adding extension…", icon: "puzzlepiece.extension")
        Task { @MainActor [weak self, weak window] in
            guard let self else { return }
            do {
                let installed = try await extensions.installFromStore(id: id)
                try await extensions.enable(slug: installed.slug, in: space)
                window?.showToast(
                    "Added \(installed.displayName ?? id)", icon: "puzzlepiece.extension"
                )
            } catch {
                window?.showToast(
                    "Could not add extension: \(error.localizedDescription)",
                    icon: "exclamationmark.triangle"
                )
            }
        }
    }
}
