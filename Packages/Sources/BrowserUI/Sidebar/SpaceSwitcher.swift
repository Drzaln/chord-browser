import BrowserCore
import BrowserStore
import SwiftUI

/// The Space strip at the top of the sidebar.
struct SpaceSwitcher: View {
    @Bindable var store: TabStore
    var isCollapsed: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingDeletion: Space?

    var body: some View {
        // The rail stacks what the full sidebar lays out in a row. A horizontal
        // strip of Spaces does not survive being 48 points wide — with three
        // Spaces and the add button it is already over budget.
        layout {
            ForEach(store.spaces.sorted { $0.sortIndex < $1.sortIndex }) { space in
                spaceButton(space)
            }

            if !isCollapsed { Spacer(minLength: 0) }

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
            .help(isCollapsed ? "New Space" : "")
        }
        .padding(.horizontal, isCollapsed ? 0 : 10)
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
    }

    /// `AnyLayout` rather than an `if` around two copies of the content: the
    /// buttons keep their identity across the switch, so collapsing animates
    /// the icons into place instead of tearing them down and rebuilding them.
    private var layout: AnyLayout {
        isCollapsed
            ? AnyLayout(VStackLayout(spacing: 6))
            : AnyLayout(HStackLayout(spacing: 6))
    }

    private func spaceButton(_ space: Space) -> some View {
        let isActive = space.id == store.activeSpace?.id

        return Button {
            withAnimation(Motion.respectingReduceMotion(
                Motion.spaceSwitch, reduceMotion: reduceMotion
            )) {
                store.selectSpace(space.id)
            }
        } label: {
            Image(systemName: space.iconSymbol)
                .font(.system(size: 11, weight: .medium))
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
        .help(space.name)
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            Button("Delete Space…", role: .destructive) { pendingDeletion = space }
                .disabled(store.spaces.count <= 1)
        }
    }
}
