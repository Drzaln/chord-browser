import BrowserStore
import SwiftUI

public struct RootView: View {
    @Bindable private var store: TabStore

    public init(store: TabStore) {
        self.store = store
    }

    public var body: some View {
        HStack(spacing: 0) {
            SidebarView(store: store)
            WebContentCard(store: store)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(.background)
        .task {
            await store.restore()
        }
    }
}
