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
        // `.hiddenTitleBar` still reserves the titlebar strip across the whole
        // window, which pushed the web card down and left a dead band above it.
        // The card runs to the top edge instead; the sidebar reserves its own
        // clearance for the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 720, minHeight: 480)
        .background(.background)
        .task {
            await store.restore()
        }
    }
}
