import ChordCore
import ChordStore
import SwiftUI

/// The "Rename Tab…" alert, presented from `RootView` rather than the sidebar so
/// it survives the sidebar collapsing (and auto-hiding) beneath it (non-spec:
/// user-requested).
///
/// The target is a tab id on `WindowState` — the same shape as the Space editor —
/// which both feeds the alert and holds the revealed sidebar open while it is on
/// screen (the pointer leaves the sidebar the moment the alert opens, so an
/// auto-hide firing then would drop the alert out from under the user).
struct RenameTabAlert: ViewModifier {
    @Bindable var store: TabStore
    @Binding var targetID: UUID?
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: targetID) { _, _ in
                let tab = store.tabs.first { $0.id == targetID }
                draft = tab?.customTitle ?? tab?.displayTitle ?? ""
            }
            .alert("Rename Tab", isPresented: presented, presenting: targetTab) { tab in
                TextField("Name", text: $draft)
                Button("Rename") {
                    store.renameTab(tab.id, to: draft)
                    targetID = nil
                }
                Button("Cancel", role: .cancel) { targetID = nil }
            } message: { tab in
                Text("This name shows in the sidebar instead of the page title.")
            }
    }

    /// The tab being renamed, resolved live so a tab closed mid-edit simply
    /// dismisses the alert instead of presenting against a dead id.
    private var targetTab: ChordCore.Tab? {
        guard let targetID else { return nil }
        return store.tabs.first { $0.id == targetID }
    }

    private var presented: Binding<Bool> {
        Binding(
            get: { targetTab != nil },
            set: { if !$0 { targetID = nil } }
        )
    }
}