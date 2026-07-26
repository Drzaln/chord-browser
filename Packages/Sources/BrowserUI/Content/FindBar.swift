import BrowserStore
import SwiftUI

/// Find-in-page, over the top-trailing corner of the content (M6).
///
/// No "3 of 12" counter, because WebKit will not tell us: `WKFindResult`
/// carries `matchFound` and nothing else — no total, no index. A counter would
/// have to be built by injecting a script that walks and marks the DOM, which
/// is a page-rewriting mechanism this app does not otherwise need. Found or
/// not found is what the API supports, so it is what the bar says.
struct FindBar: View {
    @Bindable var store: TabStore
    /// The window this view belongs to — its selection, its Space.
    @Bindable var windowState: WindowState

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Find on page", text: $windowState.findText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 160)
                .focused($isFieldFocused)
                // Return finds the next match. A focused `TextField` consumes
                // Return for its own submit, so this is the only hook that
                // sees it — see the keyboard hazards in CHECKPOINT.
                .onSubmit { store.findNext(in: windowState) }
                // Searching as you type, which is the behaviour everywhere
                // else. The store cancels the in-flight query, so a fast
                // typist does not get an answer for a prefix they have already
                // moved past.
                .onChange(of: windowState.findText) { store.findNext(in: windowState) }

            if windowState.findFoundMatch == false {
                Text("Not found")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            button("chevron.up", label: "Previous Match") { store.findPrevious(in: windowState) }
            button("chevron.down", label: "Next Match") { store.findNext(in: windowState) }
            button("xmark", label: "Close Find Bar") { store.hideFindBar(in: windowState) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(Metrics.shadowOpacity), radius: 8, y: 2)
        }
        .overlay {
            // A miss is worth showing on the bar itself; the page has not
            // moved, so nothing else on screen changed to say so.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    windowState.findFoundMatch == false ? Color.red.opacity(0.6) : .clear,
                    lineWidth: 1
                )
        }
        .padding(Metrics.contentInset + 6)
        // Esc dismisses, as it does in the command bar.
        .onExitCommand { store.hideFindBar(in: windowState) }
        .onAppear { isFieldFocused = true }
        // The bar is rebuilt on each presentation rather than kept alive, so
        // `onAppear` is a reliable place to take focus here — unlike the
        // command bar's panel, which is built once and reused.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find on page")
    }

    private func button(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}
