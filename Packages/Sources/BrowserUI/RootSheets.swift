import BrowserCore
import BrowserExtensions
import BrowserStore
import SwiftUI

/// Every sheet and dialog `RootView` presents, in one modifier.
///
/// Split out of `RootView.body` for a compiler reason rather than a design one:
/// with all five inline, the body's single expression stopped type-checking in
/// reasonable time. Presenting them at the root is still deliberate — each one
/// must survive the sidebar collapsing (and auto-hiding) beneath it.
struct RootSheets: ViewModifier {
    @Bindable var store: TabStore
    @Bindable var windowState: WindowState
    let extensions: ExtensionsService?

    /// The Space being edited, resolved against the shared store. Written back
    /// as `nil` only, since dismissal is the sheet's own doing.
    private var editingSpace: Binding<Space?> {
        Binding(
            get: { store.spaces.first { $0.id == windowState.editingSpaceID } },
            set: { if $0 == nil { windowState.editingSpaceID = nil } }
        )
    }

    /// Extension permission prompts, one at a time (7.5c). A dismiss without a
    /// decision (Esc / swipe) is treated as a denial by the setter.
    private var pendingPermission: Binding<PermissionRequest?> {
        Binding(
            get: { store.pendingPermissionRequests.first },
            set: { newValue in
                if newValue == nil, let current = store.pendingPermissionRequests.first {
                    store.resolvePermissionRequest(current.id, allow: false)
                }
            }
        )
    }

    /// Camera/mic/notification prompts, one at a time (non-spec: user-requested).
    /// A dismiss without a decision (Esc / swipe) is treated as a denial.
    private var pendingSitePermission: Binding<SitePermissionPrompt?> {
        Binding(
            get: { store.pendingSitePermissionPrompts.first },
            set: { newValue in
                if newValue == nil, let current = store.pendingSitePermissionPrompts.first {
                    store.resolveSitePermission(current.id, allow: false)
                }
            }
        )
    }

    private var isDeletingSpace: Binding<Bool> {
        Binding(
            get: { windowState.deletingSpaceID != nil },
            set: { if !$0 { windowState.deletingSpaceID = nil } }
        )
    }

    /// A tab dragged in from another window, which would change its Space.
    private var isMovingTab: Binding<Bool> {
        Binding(
            get: { windowState.pendingTabMove != nil },
            set: { if !$0 { store.cancelPendingTabMove(in: windowState) } }
        )
    }

    private var deletingSpaceName: String {
        store.spaces.first { $0.id == windowState.deletingSpaceID }?.name ?? ""
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: editingSpace) { space in
                SpaceEditor(store: store, space: space)
            }
            .sheet(item: pendingPermission) { request in
                ExtensionPermissionSheet(request: request, store: store)
            }
            .sheet(item: pendingSitePermission) { prompt in
                SitePermissionSheet(prompt: prompt, store: store)
            }
            .sheet(isPresented: $windowState.isSettingsPresented) {
                SettingsView(store: store, windowState: windowState, extensions: extensions)
            }
            .sheet(isPresented: $windowState.isHistoryPresented) {
                HistoryView(store: store, windowState: windowState)
            }
            // Dropping a tab into a window showing a different Space moves it
            // between Spaces, and each Space has its own cookie store — so the
            // page comes back signed out. Worth a prompt; Arc asks too.
            .confirmationDialog(
                "Move “\(windowState.pendingTabMove?.tabTitle ?? "")” to \(windowState.pendingTabMove?.toSpaceName ?? "")?",
                isPresented: isMovingTab,
                titleVisibility: .visible
            ) {
                Button("Move Tab") { store.confirmPendingTabMove(in: windowState) }
                Button("Cancel", role: .cancel) {
                    store.cancelPendingTabMove(in: windowState)
                }
            } message: {
                Text(
                    """
                    \(windowState.pendingTabMove?.toSpaceName ?? "") uses a separate                     profile, so this tab may be signed out of any sites it is                     logged in to.
                    """
                )
            }
            .confirmationDialog(
                "Delete “\(deletingSpaceName)”?",
                isPresented: isDeletingSpace,
                titleVisibility: .visible
            ) {
                Button("Delete Space and Its Data", role: .destructive) {
                    guard let spaceID = windowState.deletingSpaceID else { return }
                    windowState.deletingSpaceID = nil
                    Task { await store.deleteSpace(spaceID, in: windowState) }
                }
                Button("Cancel", role: .cancel) { windowState.deletingSpaceID = nil }
            } message: {
                // 3.3: reclaiming the data store is irreversible, so say so plainly.
                Text("Its tabs, cookies, and cached data are removed permanently.")
            }
    }
}
