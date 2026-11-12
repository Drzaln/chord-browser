import ChordCore
import ChordStore
import SwiftUI

/// The first-run welcome (gn0.6, non-spec: user-requested): one sheet, three
/// optional steps, each skippable, then where the two things you need are.
///
/// Shown once, to a profile that had nothing in it (`WelcomePolicy`). It is a
/// sheet over the already-painted window, so it costs the launch nothing.
struct WelcomeSheet: View {
    @Bindable var store: TabStore
    @Bindable var windowState: WindowState

    @State private var defaultBrowser = DefaultBrowserModel(control: WorkspaceDefaultBrowser())

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Chord").font(.system(size: 20, weight: .semibold))
                Text("Three things you can set up now, or skip and do later.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            step(
                symbol: "safari",
                title: "Make Chord your default browser",
                detail: defaultBrowser.isDefault
                    ? "Chord is your default browser."
                    : "Links from other apps will open here. macOS asks you to confirm."
            ) {
                if defaultBrowser.isDefault {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Done")
                } else {
                    Button("Make Default") {
                        Task { await defaultBrowser.makeDefault() }
                    }
                    .disabled(defaultBrowser.isAsking)
                }
            }

            step(
                symbol: "square.and.arrow.down",
                title: "Bring your things across",
                detail: "In the File menu: Import Bookmarks… (an HTML export from any browser), Import from Arc…, and Import Passwords… (Chrome, Brave, Edge)."
            ) { EmptyView() }

            step(
                symbol: "square.stack",
                title: "Name your first Space",
                detail: "A Space keeps its own tabs, pins and sign-ins. Give this one a name and a colour."
            ) {
                Button("Edit Space…") { editSpace() }
                    .disabled(store.activeSpace(in: windowState) == nil)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                tip("⌘T", "opens the command bar: type an address, a search, or a tab's name.")
                tip("⌘,", "opens Settings.")
            }

            HStack {
                Spacer()
                Button("Get Started") { windowState.isWelcomePresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { defaultBrowser.refresh() }
    }

    private func step<Trailing: View>(
        symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }

    private func tip(_ keys: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 26, alignment: .leading)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// One sheet at a time: close the welcome, then open the Space editor on
    /// the next turn so the two presentations do not collide.
    private func editSpace() {
        guard let space = store.activeSpace(in: windowState) else { return }
        windowState.isWelcomePresented = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            windowState.editingSpaceID = space.id
        }
    }
}
