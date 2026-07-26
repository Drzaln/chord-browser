import BrowserCore
import Foundation

/// Sidebar folders (non-spec: user-requested). Folders group tabs within a Space
/// and exempt them from the ephemeral sweep. Membership lives on the tab
/// (`folderID`), so moving a tab persists through the normal tab save; the folder
/// rows themselves persist separately.
@MainActor
extension TabStore {

    /// The active Space's folders, in sidebar order.
    public var activeSpaceFolders: [Folder] {
        guard let spaceID = primaryWindow.activeSpaceID else { return [] }
        return folders
            .filter { $0.spaceID == spaceID }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    /// The tabs inside a folder, in placement order.
    public func tabs(inFolder folderID: UUID) -> [Tab] {
        visibleTabs
            .filter { $0.folderID == folderID }
            .sorted { $0.placement.order < $1.placement.order }
    }

    // MARK: - Mutations

    /// Creates a folder in the active Space and returns its id.
    @discardableResult
    public func addFolder(name: String = "New Folder") -> UUID? {
        guard let spaceID = primaryWindow.activeSpaceID else { return nil }
        let sortIndex = (folders.filter { $0.spaceID == spaceID }.map(\.sortIndex).max() ?? -1) + 1
        let folder = Folder(spaceID: spaceID, name: name, sortIndex: sortIndex)
        folders.append(folder)
        persistFolders()
        return folder.id
    }

    public func renameFolder(_ folderID: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].name = name
        persistFolders()
    }

    public func toggleFolderCollapsed(_ folderID: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].isCollapsed.toggle()
        persistFolders()
    }

    /// Deletes a folder. Its tabs are kept — they simply become loose (or return
    /// to Favourites if pinned) rather than being closed.
    public func deleteFolder(_ folderID: UUID) {
        for index in tabs.indices where tabs[index].folderID == folderID {
            tabs[index].folderID = nil
        }
        folders.removeAll { $0.id == folderID }
        persistFolders()
        scheduleSave()
    }

    /// Moves a tab into a folder, or out of any folder when `folderID` is nil.
    /// Placement (pinned/ephemeral) is preserved; membership is what changes.
    public func moveTab(_ tabID: UUID, toFolder folderID: UUID?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if let folderID { guard folders.contains(where: { $0.id == folderID }) else { return } }
        guard tabs[index].folderID != folderID else { return }

        // Order densely within the destination folder (or the loose list) so the
        // moved tab lands at the end rather than colliding with a sibling.
        let spaceID = tabs[index].spaceID
        let order = tabs
            .filter { $0.spaceID == spaceID && $0.folderID == folderID }
            .map(\.placement.order)
            .max()
            .map { $0 + 1 } ?? 0

        tabs[index].folderID = folderID
        tabs[index].placement = tabs[index].placement.withOrder(order)
        scheduleSave()
    }

    // MARK: - Persistence

    func persistFolders() {
        let snapshot = folders
        Task { [folderRepository] in
            do {
                try await folderRepository?.saveFolders(snapshot)
            } catch {
                Log.store.error("folder save failed: \(String(describing: error))")
            }
        }
    }
}
