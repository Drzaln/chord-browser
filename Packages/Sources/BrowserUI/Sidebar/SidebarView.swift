import BrowserCore
import BrowserStore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: TabStore

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(store: store)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            // Lazy so a large tab list does not build every row up front (6.4).
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.tabs) { tab in
                        TabRowView(
                            tab: tab,
                            isSelected: tab.id == store.selectedTabID,
                            select: { store.select(tab.id) },
                            close: { store.closeTab(tab.id) }
                        )
                        .id(tab.id)  // stable identity, so rows are not rebuilt
                    }
                }
                .padding(.horizontal, 8)
            }

            newTabButton
        }
        .frame(width: Metrics.sidebarWidth)
        .background(.regularMaterial)
    }

    private var newTabButton: some View {
        Button {
            store.newTab()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("New Tab")
                    .font(.system(size: 12))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: Metrics.sidebarRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(8)
        .keyboardShortcut("t", modifiers: .command)
    }
}
