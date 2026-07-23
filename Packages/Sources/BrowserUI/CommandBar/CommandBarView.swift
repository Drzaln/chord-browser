import BrowserCore
import BrowserStore
import SwiftUI

/// The command bar's contents: one input, one ranked result list (4.4).
struct CommandBarView: View {
    @Bindable var store: TabStore
    let dismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    private var results: [Suggestion] { store.suggestions(for: query) }

    var body: some View {
        VStack(spacing: 0) {
            input

            if !results.isEmpty {
                Divider()
                resultList
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .onAppear {
            // The bar is built once and reused, so state is reset on show
            // rather than on construction.
            query = ""
            highlighted = 0
            isFocused = true
        }
        .onChange(of: query) { highlighted = 0 }
    }

    private var input: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search or enter address", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($isFocused)
                .onSubmit { activate(forceNewTab: false) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, suggestion in
                        CommandBarRow(
                            suggestion: suggestion,
                            isHighlighted: index == highlighted
                        )
                        .id(suggestion.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            highlighted = index
                            activate(forceNewTab: false)
                        }
                    }
                }
            }
            .frame(maxHeight: 340)
            .onChange(of: highlighted) {
                guard results.indices.contains(highlighted) else { return }
                proxy.scrollTo(results[highlighted].id)
            }
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        // Wraps, so holding down arrow at the end returns to the top.
        highlighted = (highlighted + delta + results.count) % results.count
        return .handled
    }

    private func activate(forceNewTab: Bool) {
        guard results.indices.contains(highlighted) else { return }
        store.activate(results[highlighted], forceNewTab: forceNewTab)
        dismiss()
    }
}

struct CommandBarRow: View {
    let suggestion: Suggestion
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(suggestion.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isHighlighted ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
    }

    private var symbol: String {
        switch suggestion.kind {
        case .openTab: "square.on.square"
        case .history: "clock"
        case .archived: "arrow.uturn.backward"
        case .command: "command"
        case .navigate: "arrow.right"
        case .search: "magnifyingglass"
        }
    }
}
