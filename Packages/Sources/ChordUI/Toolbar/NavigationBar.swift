import ChordCore
import ChordStore
import SwiftUI

/// Back / forward / reload and the address field.
///
/// Observes the focused pane's `PaneRuntime` rather than the whole store, so a
/// loading progress tick redraws this bar and nothing else (6.4).
struct NavigationBar: View {
    @Bindable var store: TabStore
    /// The window this view belongs to — its selection, its Space.
    @Bindable var windowState: WindowState
    @Bindable var downloads: DownloadsStore
    /// The active Space's colour, tinting the address button to match the tabs
    /// (item 4).
    var tint: Color = .accentColor
    /// Opens the command bar pre-filled with the current URL, like Cmd+L.
    var openCommandBar: (CommandBarMode, String?) -> Void = { _, _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var runtime: PaneRuntime? {
        store.selectedTab(in: windowState).map { store.runtime(for: $0.focusedPaneID) }
    }

    /// The address shown on the button, live from the focused pane.
    private var currentURLString: String {
        runtime?.currentURL?.absoluteString
            ?? store.selectedTab(in: windowState)?.focusedPane.url.absoluteString
            ?? ""
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                button("chevron.left", label: "Back", enabled: runtime?.canGoBack ?? false) {
                    store.goBack(in: windowState)
                }
                .keyboardShortcut("[", modifiers: .command)

                button(
                    "chevron.right", label: "Forward", enabled: runtime?.canGoForward ?? false
                ) {
                    store.goForward(in: windowState)
                }
                .keyboardShortcut("]", modifiers: .command)

                if runtime?.isLoading == true {
                    button("xmark", label: "Stop", enabled: true) { store.stopLoading(in: windowState) }
                } else {
                    button("arrow.clockwise", label: "Reload", enabled: true) { store.reload(in: windowState) }
                }

                DownloadsButton(downloads: downloads)

                // Only rendered when this page has a login and something is
                // saved for it (V6 of the password vault).
                CredentialFillButton(store: store, windowState: windowState)

                addressField
            }

            progressBar
        }
    }

    /// A button, not an editable field: clicking it opens the command bar with
    /// the current URL, exactly like Cmd+L (item 3). Editing happens there, with
    /// the same ranked results as everywhere else, so the sidebar keeps a single
    /// place to type a destination.
    private var addressField: some View {
        Button {
            openCommandBar(.currentTab, currentURLString)
        } label: {
            Text(displayAddress)
                .font(.system(size: 12))
                .foregroundStyle(currentURLString.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    // Tinted with the Space colour, matching the tabs (item 4).
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint.opacity(0.18))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Edit address")
        .accessibilityLabel("Address: \(displayAddress)")
    }

    /// The host alone when there is one — shorter and calmer than the full URL,
    /// the way a modern browser's collapsed address reads — falling back to the
    /// whole string, then a prompt.
    private var displayAddress: String {
        guard !currentURLString.isEmpty else { return "Search or enter address" }
        if let host = URL(string: currentURLString)?.host() {
            return host
        }
        return currentURLString
    }

    @ViewBuilder
    private var progressBar: some View {
        let progress = runtime?.estimatedProgress ?? 0
        let visible = runtime?.isLoading == true && progress > 0 && progress < 1

        GeometryReader { geometry in
            Rectangle()
                .fill(.tint)
                .frame(width: geometry.size.width * progress)
        }
        .frame(height: 2)
        .opacity(visible ? 1 : 0)
        .animation(
            Motion.respectingReduceMotion(Motion.progressBar, reduceMotion: reduceMotion),
            value: progress
        )
    }

    private func button(
        _ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}
