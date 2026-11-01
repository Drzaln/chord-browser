import ChordCore
import ChordExtensions
import ChordStore
import SwiftUI

/// The address field, in Arc's arrangement: a full-width rounded field under
/// the title-bar row, with the page's own buttons (saved login, downloads,
/// extension actions) at its trailing end. Back, forward and reload sit in the
/// title-bar row instead (`NavigationButtons`).
///
/// Observes the focused pane's `PaneRuntime` rather than the whole store, so a
/// loading progress tick redraws this bar and nothing else (6.4).
struct NavigationBar: View {
    @Bindable var store: TabStore
    /// The window this view belongs to — its selection, its Space.
    @Bindable var windowState: WindowState
    @Bindable var downloads: DownloadsStore
    /// Opens the command bar pre-filled with the current URL, like Cmd+L.
    var openCommandBar: (CommandBarMode, String?) -> Void = { _, _ in }
    /// The extension host; its toolbar actions sit at the field's end, as
    /// Arc keeps extension buttons in its address field.
    var extensionHost: (any ExtensionHost)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHoveringAddress = false
    @State private var isExtensionsPanelOpen = false

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
            HStack(spacing: 2) {
                addressField

                // Only rendered when this page has a login and something is
                // saved for it (V6 of the password vault).
                CredentialFillButton(store: store, windowState: windowState)

                DownloadsButton(downloads: downloads, windowState: windowState)

                // Under the pointer only (and while a popup or the manage
                // panel is open), as in Arc: shown always they left a narrow
                // sidebar's field room for a few letters of the address.
                if let extensionHost {
                    if isHoveringAddress || isExtensionsPanelOpen
                        || windowState.isExtensionPopupOpen {
                        ExtensionActionsBar(
                            store: store, windowState: windowState, host: extensionHost,
                            onPanelShown: { isExtensionsPanelOpen = $0 }
                        )
                    } else if let space = store.activeSpace(in: windowState) {
                        // Something to hang a popup from while the buttons are
                        // away: an extension can open its own (a shortcut,
                        // Bitwarden's autofill prompt), and the host falls back
                        // to this anchor when the extension's button is gone.
                        PopoverAnchorView { view in
                            extensionHost.registerActionAnchor(
                                view, forSlug: WebKitExtensionHost.managerAnchorSlug, in: space
                            )
                        }
                        .frame(width: 1, height: 16)
                        .id(space.id)
                    }
                }
            }
            .padding(.trailing, 6)
            .frame(height: Metrics.addressFieldHeight)
            .background(
                // A neutral lift over the Space's tint, as Arc's field: darker
                // on a light sidebar, lighter on a dark one, a little more
                // under the pointer so it reads as clickable.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isHoveringAddress ? 0.10 : 0.07))
            )
            .onHover { hovering in
                withAnimation(Motion.respectingReduceMotion(.easeOut(duration: 0.12), reduceMotion: reduceMotion)) {
                    isHoveringAddress = hovering
                }
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
            HStack(spacing: 8) {
                if currentURLString.isEmpty {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(displayAddress)
                    .font(.system(size: 13))
                    .foregroundStyle(currentURLString.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .frame(maxHeight: .infinity)
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
        guard !currentURLString.isEmpty else { return "Search or Enter URL…" }
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
}

/// Back, forward and reload (stop while loading), at the trailing end of the
/// title-bar row beside the traffic lights, as Arc places them.
struct NavigationButtons: View {
    @Bindable var store: TabStore
    @Bindable var windowState: WindowState

    private var runtime: PaneRuntime? {
        store.selectedTab(in: windowState).map { store.runtime(for: $0.focusedPaneID) }
    }

    var body: some View {
        HStack(spacing: 4) {
            button("arrow.left", label: "Back", enabled: runtime?.canGoBack ?? false) {
                store.goBack(in: windowState)
            }
            .keyboardShortcut("[", modifiers: .command)

            button("arrow.right", label: "Forward", enabled: runtime?.canGoForward ?? false) {
                store.goForward(in: windowState)
            }
            .keyboardShortcut("]", modifiers: .command)

            if runtime?.isLoading == true {
                button("xmark", label: "Stop", enabled: true) { store.stopLoading(in: windowState) }
            } else {
                button("arrow.clockwise", label: "Reload", enabled: true) { store.reload(in: windowState) }
            }
        }
    }

    private func button(
        _ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .hoverHighlight(opacity: enabled ? 0.12 : 0)
        .accessibilityLabel(label)
    }
}
