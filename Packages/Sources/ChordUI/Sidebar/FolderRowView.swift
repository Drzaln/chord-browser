import ChordCore
import SwiftUI

/// A folder header in the sidebar: a disclosure chevron, the name (editable
/// inline), and a tab count (non-spec: user-requested).
struct FolderRowView: View {
    let folder: Folder
    let isRenaming: Bool
    let toggleCollapsed: () -> Void
    let rename: (String) -> Void
    let beginRename: () -> Void
    let delete: () -> Void

    @State private var isHovering = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: folder.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if isRenaming {
                TextField("Folder name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .focused($nameFocused)
                    .onSubmit { rename(draftName) }
                    .onAppear { draftName = folder.name; nameFocused = true }
            } else {
                Text(folder.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isHovering && !isRenaming {
                Button(action: beginRename) {
                    Image(systemName: "pencil").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .help("Rename folder")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.sidebarRowHeight)
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { toggleCollapsed() } }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename") { beginRename() }
            Button(folder.isCollapsed ? "Expand" : "Collapse") { toggleCollapsed() }
            Divider()
            Button("Delete Folder", role: .destructive) { delete() }
        }
        .accessibilityLabel("Folder \(folder.displayName)")
    }
}
