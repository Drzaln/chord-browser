import BrowserCore
import BrowserStore
import SwiftUI

/// The Space strip on the sidebar's bottom bar.
struct SpaceSwitcher: View {
    @Bindable var store: TabStore
    /// The Edit/Delete Space items drive this window's sheets.
    @Bindable var windowState: WindowState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // `visibleSpaces`: a private window's throwaway Space belongs to that
                    // window alone and must not appear in anyone else's switcher.
                    ForEach(store.visibleSpaces.sorted { $0.sortIndex < $1.sortIndex }) { space in
                        spaceButton(space)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Spacer(minLength: 0)

            Button {
                store.addSpace(in: windowState)
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
    }

    private func spaceButton(_ space: Space) -> some View {
        let isActive = space.id == store.activeSpace(in: windowState)?.id
        let isDragging = store.draggingTabID != nil

        return Button {
            withAnimation(Motion.respectingReduceMotion(
                Motion.spaceSwitch, reduceMotion: reduceMotion
            )) {
                store.selectSpace(space.id, in: windowState)
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
        // Dropping a dragged tab onto a Space moves it there (4.1). Routed through
        // `dropTab(_:ontoSpace:)` so a cross-Space move prompts first, like every
        // other cross-Space drag. Mounted only while a drag is in flight so it
        // never eats an ordinary click on the Space button.
        .overlay {
            if isDragging {
                SidebarDropTarget(
                    onDrop: { tabID, _ in store.dropTab(tabID, ontoSpace: space.id, in: windowState) }
                )
            }
        }
        .help(space.name)
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            Button("Edit Space…") { windowState.editingSpaceID = space.id }
            Divider()
            Button("Delete Space…", role: .destructive) { windowState.deletingSpaceID = space.id }
                .disabled(store.visibleSpaces.count <= 1)
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
