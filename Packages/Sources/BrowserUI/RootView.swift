import BrowserStore
import SwiftUI

public struct RootView: View {
    @Bindable private var store: TabStore
    @Bindable private var downloads: DownloadsStore

    public init(store: TabStore, downloads: DownloadsStore) {
        self.store = store
        self.downloads = downloads
    }

    public var body: some View {
        HStack(spacing: 0) {
            SidebarView(store: store, downloads: downloads)
            WebContentCard(store: store)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(.background)
        .task {
            await store.restore()
        }
    }
}
