import AppKit
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

    /// Widths as they were when the current divider drag began. Applying a
    /// drag's translation to a live baseline compounds it.
    @State private var dragBase: [Double]?
    @State private var dragEndMonitor: Any?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(tab.panes.enumerated()), id: \.element.id) { index, pane in
                    paneView(pane, width: width(of: pane, in: geometry.size.width))

                    if index < tab.panes.count - 1 {
                        PaneDivider(
                            onDragBegan: { dragBase = tab.panes.map(\.widthFraction) },
                            onDrag: { translation in
                                // Points to a fraction here, so the store and
                                // the layout maths stay free of view geometry.
                                guard geometry.size.width > 0, let dragBase else { return }
                                store.resizePanes(
                                    in: tab.id,
                                    dividerAfter: index,
                                    by: translation / geometry.size.width,
                                    from: dragBase
                                )
                            },
                            onDragEnded: { dragBase = nil }
                        )
                    }
                }
            }
        }
        // A cancelled drag never reaches a drop handler, and a stale flag would
        // leave the drop layer above the page eating clicks. Mouse-up ends the
        // drag session whatever the outcome.
        .onChange(of: store.draggingTabID != nil) { _, isDragging in
            if isDragging { watchForDragEnd() } else { stopWatchingForDragEnd() }
        }
        .onDisappear(perform: stopWatchingForDragEnd)
    }

    private func watchForDragEnd() {
        guard dragEndMonitor == nil else { return }
        dragEndMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            store.endTabDrag()
            return event
        }
    }

    private func stopWatchingForDragEnd() {
        if let dragEndMonitor { NSEvent.removeMonitor(dragEndMonitor) }
        dragEndMonitor = nil
    }

    private func width(of pane: Pane, in total: CGFloat) -> CGFloat {
        // Dividers eat a few points; splitting the remainder by fraction keeps
        // the panes from overflowing their container.
        let dividerTotal = CGFloat(max(tab.panes.count - 1, 0)) * Metrics.splitDividerWidth
        return max(0, (total - dividerTotal) * pane.widthFraction)
    }

    private func paneView(_ pane: Pane, width: CGFloat) -> some View {
        let position = tab.panes.firstIndex { $0.id == pane.id } ?? 0
        return PaneCard(
            store: store,
            tab: tab,
            pane: pane,
            isFocused: pane.id == tab.focusedPaneID,
            showsFocusRing: tab.panes.count > 1,
            isFirst: position == 0,
            isLast: position == tab.panes.count - 1
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
    let isFirst: Bool
    let isLast: Bool

    @State private var isDropTarget = false

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
            // Which pane the keyboard acts on is otherwise invisible. A drop
            // target outranks it: during a drag, where the tab will land is the
            // more urgent question.
            if isDropTarget {
                RoundedRectangle(cornerRadius: Metrics.contentCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: Metrics.splitDropRingWidth)
                    .background(
                        RoundedRectangle(
                            cornerRadius: Metrics.contentCornerRadius, style: .continuous
                        )
                        .fill(Color.accentColor.opacity(0.12))
                    )
            } else if showsFocusRing {
                RoundedRectangle(cornerRadius: Metrics.contentCornerRadius, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.accentColor.opacity(0.9) : .clear,
                        lineWidth: Metrics.splitFocusRingWidth
                    )
            }
        }
        .overlay {
            // Only while a tab is actually in flight. A permanent layer here
            // would sit above the web view and swallow every click; without a
            // layer at all, the web view swallows the *drop*, because it
            // registers for dragged types itself and is above our destination.
            if store.draggingTabID != nil {
                TabDropTarget(
                    isTargeted: { isDropTarget = $0 },
                    onDrop: { sourceID in
                        store.endTabDrag()
                        store.split(tab.id, byMoving: sourceID)
                    }
                )
            }
        }
        // Only the outer edges carry the inset. Insetting the inner edges too
        // put 8 + divider + 8 points of dead space between panes, which reads
        // as a very thick divider rather than as breathing room.
        .padding(.vertical, Metrics.contentInset)
        .padding(.leading, isFirst ? Metrics.contentInset : 0)
        .padding(.trailing, isLast ? Metrics.contentInset : 0)
        // Clicking a pane focuses it. `simultaneousGesture` rather than
        // `onTapGesture`, so the click still reaches the web view — otherwise
        // the first click into an unfocused pane would only focus it and the
        // link under the cursor would be swallowed.
        .simultaneousGesture(TapGesture().onEnded { store.focusPane(pane.id) })
    }
}

/// The draggable divider between two panes.
private struct PaneDivider: View {
    let onDragBegan: () -> Void
    let onDrag: (CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var isDragging = false

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
                // `.global`, because this view *moves* as the drag resizes the
                // panes around it. In the default local space the origin moves
                // with it, so translation is measured against a shifting frame
                // and the divider lags and stutters behind the cursor.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onDragBegan()
                        }
                        // Total translation from the drag's start, applied to
                        // the widths captured at the same moment.
                        onDrag(value.translation.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onDragEnded()
                    }
            )
    }
}

