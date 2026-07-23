import BrowserCore
import BrowserStore
import SwiftUI

/// Lays a tab's panes out side by side with draggable dividers (4.5).
///
/// A single-pane tab renders exactly as it always did — no divider, no overlay,
/// no extra container — so the normal case pays nothing for split view existing.
struct SplitContentView: View {
    @Bindable var store: TabStore
    let tab: BrowserCore.Tab

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(tab.panes.enumerated()), id: \.element.id) { index, pane in
                    paneView(pane, width: width(of: pane, in: geometry.size.width))

                    if index < tab.panes.count - 1 {
                        PaneDivider(
                            onDrag: { translation in
                                // Points to a fraction here, so the store and
                                // the layout maths stay free of view geometry.
                                guard geometry.size.width > 0 else { return }
                                store.resizePanes(
                                    in: tab.id,
                                    dividerAfter: index,
                                    by: translation / geometry.size.width
                                )
                            }
                        )
                    }
                }
            }
        }
    }

    private func width(of pane: Pane, in total: CGFloat) -> CGFloat {
        // Dividers eat a few points; splitting the remainder by fraction keeps
        // the panes from overflowing their container.
        let dividerTotal = CGFloat(max(tab.panes.count - 1, 0)) * Metrics.splitDividerWidth
        return max(0, (total - dividerTotal) * pane.widthFraction)
    }

    private func paneView(_ pane: Pane, width: CGFloat) -> some View {
        PaneCard(
            store: store,
            tab: tab,
            pane: pane,
            isFocused: pane.id == tab.focusedPaneID,
            showsFocusRing: tab.panes.count > 1
        )
        .frame(width: width)
    }
}

/// One pane's web surface in its rounded card.
private struct PaneCard: View {
    @Bindable var store: TabStore
    let tab: BrowserCore.Tab
    let pane: Pane
    let isFocused: Bool
    let showsFocusRing: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.contentCornerRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(
                    color: .black.opacity(Metrics.shadowOpacity),
                    radius: Metrics.shadowRadius,
                    y: 2
                )

            if let surface = store.surface(for: pane, in: tab) {
                // Keyed by pane, so resizing or reordering swaps surfaces rather
                // than reconfiguring one in place.
                surface.id(pane.id)
            }
        }
        .overlay {
            // Which pane the keyboard acts on is otherwise invisible.
            if showsFocusRing {
                RoundedRectangle(cornerRadius: Metrics.contentCornerRadius, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.accentColor.opacity(0.9) : .clear,
                        lineWidth: Metrics.splitFocusRingWidth
                    )
            }
        }
        .padding(Metrics.contentInset)
        // Clicking a pane focuses it. `simultaneousGesture` rather than
        // `onTapGesture`, so the click still reaches the web view — otherwise
        // the first click into an unfocused pane would only focus it and the
        // link under the cursor would be swallowed.
        .simultaneousGesture(TapGesture().onEnded { store.focusPane(pane.id) })
    }
}

/// The draggable divider between two panes.
private struct PaneDivider: View {
    let onDrag: (CGFloat) -> Void

    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: Metrics.splitDividerWidth)
            .overlay {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                // Cursor rects are unreliable across a hosting view; setting it
                // on hover is what actually shows the resize affordance.
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        // Deltas, not absolute translation: the store applies
                        // each move to the current fractions.
                        onDrag(value.translation.width - lastTranslation)
                        lastTranslation = value.translation.width
                    }
                    .onEnded { _ in lastTranslation = 0 }
            )
    }
}

