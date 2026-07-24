import BrowserCore
import BrowserStore
import SwiftUI

/// The Space strip on the sidebar's bottom bar.
struct SpaceSwitcher: View {
    @Bindable var store: TabStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingDeletion: Space?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(store.spaces.sorted { $0.sortIndex < $1.sortIndex }) { space in
                spaceButton(space)
            }

            Spacer(minLength: 0)

            Button {
                store.addSpace()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("New Space")
            .help("New Space")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: .init(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Space and Its Data", role: .destructive) {
                guard let space = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await store.deleteSpace(space.id) }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            // 3.3: reclaiming the data store is irreversible, so say so plainly.
            Text("Its tabs, cookies, and cached data are removed permanently.")
        }
        // The editor sheet is presented by `RootView`, not here: the sidebar is
        // torn out of the hierarchy when it collapses/auto-hides, and a sheet
        // attached to it would vanish with it.
    }

    private func spaceButton(_ space: Space) -> some View {
        let isActive = space.id == store.activeSpace?.id
        let isDragging = store.draggingTabID != nil

        return Button {
            withAnimation(Motion.respectingReduceMotion(
                Motion.spaceSwitch, reduceMotion: reduceMotion
            )) {
                store.selectSpace(space.id)
            }
        } label: {
            icon(for: space)
                .frame(width: 24, height: 24)
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(SpaceTheme.gradient(for: space))
                    }
                }
                .foregroundStyle(isActive ? .white : .secondary)
        }
        .buttonStyle(.plain)
        // Dropping a dragged tab onto a Space moves it there (4.1). Mounted only
        // while a drag is in flight so it never eats an ordinary click on the
        // Space button.
        .overlay {
            if isDragging {
                SidebarDropTarget(
                    onDrop: { tabID, _ in store.moveTab(tabID, toSpace: space.id) }
                )
            }
        }
        .help(space.name)
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            Button("Edit Space…") { store.editingSpaceID = space.id }
            Divider()
            Button("Delete Space…", role: .destructive) { pendingDeletion = space }
                .disabled(store.spaces.count <= 1)
        }
    }

    /// An emoji is drawn as text; an SF Symbol name is looked up. `Space` decides
    /// which by whether the icon is ASCII, so a custom emoji needs no new field.
    @ViewBuilder
    private func icon(for space: Space) -> some View {
        if space.isEmojiIcon {
            Text(space.iconSymbol)
                .font(.system(size: 13))
        } else {
            Image(systemName: space.iconSymbol)
                .font(.system(size: 11, weight: .medium))
        }
    }
}
