import AppKit
import BrowserCore
import BrowserStore
import SwiftUI

/// The command bar's contents: one input, one ranked result list (4.4).
struct CommandBarView: View {
    @Bindable var store: TabStore
    /// Which window the bar is acting for this time round. Not a stored
    /// `WindowState`: the panel is built once and reused across windows, so the
    /// target is swapped per presentation (see `CommandBarTarget`).
    @Bindable var target: CommandBarTarget

    private var windowState: WindowState { target.windowState ?? store.primaryWindow }
    let session: CommandBarSession
    let dismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    private var results: [Suggestion] { store.suggestions(for: query, in: windowState) }

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
        // The bar is built once and reused, so `onAppear` fires only on the
        // first presentation. Every show is driven by the session token instead.
        .onChange(of: session.presentToken, initial: true) { reset() }
        // Cmd+Enter, routed in from the panel's key-equivalent handling.
        .onChange(of: session.activateToken) {
            // Cmd+Enter forces a new tab from any mode, splitting included.
            activate(to: session.activateForcesNewTab ? .newTab : session.mode.destination)
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
                // Plain Return only. A focused TextField consumes Return for its
                // own submit and ignores it entirely when Command is held, so
                // Cmd+Enter is caught by the panel's performKeyEquivalent and
                // routed back through the session (4.4).
                // Cmd+T opens in a new tab, Cmd+L navigates the current one,
                // Cmd+Shift+D fills a new pane (4.4, 4.5). Cmd+Enter still
                // forces a new tab from any of them.
                .onSubmit { activate(to: session.mode.destination) }
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
                            isHighlighted: index == highlighted,
                            destination: session.mode.destination
                        )
                        .id(suggestion.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            highlighted = index
                            activate(to: session.mode.destination)
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

    private func reset() {
        query = session.initialQuery
        highlighted = 0

        // Focus has to be requested after the panel is key, not while it is
        // still being ordered in — otherwise the field never becomes first
        // responder and every keystroke goes to the window instead.
        //
        // Ordering between "panel becomes key" and this view update is not
        // guaranteed, and losing the race means a bar you cannot type into, so
        // the request is repeated briefly rather than made once.
        let hasPrefill = !session.initialQuery.isEmpty
        Task { @MainActor in
            for _ in 0..<10 {
                isFocused = true
                // The field editor is the panel's first responder only once
                // focus has actually landed. `@FocusState` reads back the
                // *request* when written, so checking `isFocused` alone would
                // exit the loop before the window was ever key — exactly the
                // bar-you-cannot-type-into failure this retry exists to avoid.
                guard let keyWindow = NSApp.keyWindow, keyWindow is CommandBarPanel else {
                    try? await Task.sleep(for: .milliseconds(20))
                    continue
                }

                if let editor = keyWindow.firstResponder as? NSText {
                    // The field editor is the real first responder — focus has
                    // landed. Select the pre-filled URL so the first keystroke
                    // replaces it, matching Cmd+L.
                    if hasPrefill { editor.selectAll(nil) }
                    return
                }

                // `@FocusState` can already read true when the panel re-presents
                // over an open, focused bar (the sidebar New Tab button calls
                // `present`, not `toggle`), so the request above is a no-op and
                // the AppKit first responder is stuck on the hosting view. Route
                // focus to the field's editor directly rather than waiting on
                // SwiftUI to notice the change it does not see.
                if let content = keyWindow.contentView,
                   let textField = Self.findTextField(in: content) {
                    keyWindow.makeFirstResponder(textField)
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    /// The SwiftUI `TextField`'s underlying `NSTextField`, wherever it sits in
    /// the hosting view. Used to hand focus to the editor by hand when
    /// `@FocusState` cannot — the panel re-presenting over an already-focused
    /// field being the case that trips it.
    private static func findTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField { return textField }
        for subview in view.subviews {
            if let found = findTextField(in: subview) { return found }
        }
        return nil
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        // Wraps, so holding down arrow at the end returns to the top.
        highlighted = (highlighted + delta + results.count) % results.count
        return .handled
    }

    private func activate(to destination: ActivationDestination) {
        guard results.indices.contains(highlighted) else { return }
        store.activate(results[highlighted], destination: destination, in: windowState)
        dismiss()
    }
}

struct CommandBarRow: View {
    let suggestion: Suggestion
    let isHighlighted: Bool
    /// Decides the row's action text: the same result reads "Switch to Tab" or
    /// "Move to Split" depending on how the bar was opened (4.4).
    let destination: ActivationDestination

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

            Spacer(minLength: 12)

            // What Return will do, on the row itself. A cross-Space "Switch to
            // Tab" is otherwise indistinguishable from a navigation until it
            // has already happened.
            HStack(spacing: 6) {
                Text(suggestion.actionLabel(for: destination))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isHighlighted ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
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
