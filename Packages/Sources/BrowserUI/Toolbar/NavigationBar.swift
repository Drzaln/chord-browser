import BrowserCore
import BrowserStore
import SwiftUI

/// Back / forward / reload and the address field.
///
/// Observes the focused pane's `PaneRuntime` rather than the whole store, so a
/// loading progress tick redraws this bar and nothing else (6.4).
struct NavigationBar: View {
    @Bindable var store: TabStore

    @State private var text: String = ""
    @FocusState private var isFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var runtime: PaneRuntime? {
        store.selectedTab.map { store.runtime(for: $0.focusedPaneID) }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                button("chevron.left", label: "Back", enabled: runtime?.canGoBack ?? false) {
                    store.goBack()
                }
                .keyboardShortcut("[", modifiers: .command)

                button(
                    "chevron.right", label: "Forward", enabled: runtime?.canGoForward ?? false
                ) {
                    store.goForward()
                }
                .keyboardShortcut("]", modifiers: .command)

                if runtime?.isLoading == true {
                    button("xmark", label: "Stop", enabled: true) { store.stopLoading() }
                } else {
                    button("arrow.clockwise", label: "Reload", enabled: true) { store.reload() }
                }

                addressField
            }

            progressBar
        }
        .onChange(of: store.selectedTabID) { syncField() }
        .onChange(of: runtime?.currentURL) { syncField() }
        .onAppear { syncField() }
    }

    private var addressField: some View {
        TextField("Search or enter address", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .focused($isFieldFocused)
            .onSubmit {
                guard let url = URLInput.resolve(text) else { return }
                store.navigate(to: url)
                isFieldFocused = false
            }
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

    /// The field shows the live URL except while the user is typing in it.
    private func syncField() {
        guard !isFieldFocused else { return }
        text = runtime?.currentURL?.absoluteString
            ?? store.selectedTab?.focusedPane.url.absoluteString
            ?? ""
    }
}
