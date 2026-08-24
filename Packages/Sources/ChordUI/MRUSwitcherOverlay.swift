import ChordCore
import ChordStore
import SwiftUI

/// Arc's Ctrl+Tab switcher: while Ctrl is held, a horizontal row of cards — one
/// per tab in most-recently-used order, left to right. Each card shows a page
/// thumbnail (captured via `WKWebView.takeSnapshot` when one is available) and,
/// below it, the favicon and web name. The card the cursor points at scales up
/// and gains the Space's accent; releasing Ctrl commits it.
///
/// Purely presentational and non-interactive (`allowsHitTesting(false)`): the
/// store drives the list and the cursor, and the keys keep flowing past to the
/// key monitor, which steps the cursor.
///
/// The thumbnail is the page's real content when a capture exists, and a
/// favicon-on-tint tile otherwise. Captures happen only while a pane is on
/// screen (the switcher's candidates are all detached, so their views cannot be
/// snapshot) — a page whose thumbnail is missing was never shown this session,
/// or its capture was rejected as blank because it had not painted yet.
struct MRUSwitcherOverlay: View {
    let store: TabStore
    let windowState: WindowState

    private var tint: Color {
        SpaceTheme.accent(for: store.activeSpace(in: windowState) ?? Space.makeDefault())
    }

    private static let cardWidth: CGFloat = 176
    private static let thumbnailHeight: CGFloat = 110

    /// The Space's tabs keyed by id. Built once per render so the card rows
    /// resolve their tab in O(1) instead of scanning the tab list each — the
    /// switcher re-renders on every cursor step, and a scan-per-row would be
    /// O(cards × tabs). `store.tabs` directly (no ordering sort — the MRU ids
    /// are already ordered); lookups only ever hit the active Space's ids.
    private var tabsByID: [UUID: ChordCore.Tab] {
        Dictionary(
            store.tabs.map { ($0.id, $0) },
            uniquingKeysWith: { _, new in new }
        )
    }

    var body: some View {
        // The row must be centred on the window, not glued to its left edge, and
        // the pill should hug the cards rather than span the whole width. So the
        // material background sits on the *content* (inside the scroll view) and
        // the content is stretched to at least the window's width and centred —
        // a narrow row floats in the middle, a wide one fills and scrolls.
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Array(windowState.mruTabIDs.enumerated()), id: \.element) { index, tabID in
                            if let tab = tabsByID[tabID] {
                                card(for: tab, isHighlighted: index == (windowState.mruCursor ?? 0))
                                    .id(tab.id)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.regularMaterial)
                            .shadow(color: .black.opacity(0.25), radius: 28, y: 14)
                    }
                    // A small margin either side so the pill clears the window
                    // edges when the row fills the width, and the full overlay
                    // height so it floats vertically centred too.
                    .frame(
                        minWidth: max(0, geo.size.width - 48),
                        minHeight: geo.size.height,
                        alignment: .center
                    )
                }
                .onChange(of: windowState.mruCursor) { _, cursor in
                    guard let cursor, windowState.mruTabIDs.indices.contains(cursor) else { return }
                    // Keep the aimed-at card centred as the user steps the list.
                    withAnimation(
                        Motion.respectingReduceMotion(
                            Motion.spaceSwitch,
                            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        )
                    ) {
                        proxy.scrollTo(windowState.mruTabIDs[cursor], anchor: .center)
                    }
                }
            }
        }
        .frame(height: 200)
        .allowsHitTesting(false)
    }

    private func card(for tab: ChordCore.Tab, isHighlighted: Bool) -> some View {
        VStack(spacing: 8) {
            thumbnail(for: tab, isHighlighted: isHighlighted)

            HStack(spacing: 5) {
                favicon(for: tab)
                    .frame(width: Metrics.faviconSize, height: Metrics.faviconSize)
                Text(tab.displayTitle)
                    .font(.system(size: 11, weight: isHighlighted ? .semibold : .regular))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: Self.cardWidth, alignment: .leading)
        }
        .scaleEffect(isHighlighted ? 1.06 : 1)
        .animation(Motion.tabSelection, value: isHighlighted)
    }

    private func thumbnail(for tab: ChordCore.Tab, isHighlighted: Bool) -> some View {
        Group {
            if let data = store.thumbnail(for: tab.focusedPaneID),
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                // No capture yet (a pane never shown, or a background pane
                // whose view is detached): a favicon-on-tint tile.
                placeholderTile(for: tab, isHighlighted: isHighlighted)
            }
        }
        .frame(width: Self.cardWidth, height: Self.thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isHighlighted ? tint : Color.primary.opacity(0.12),
                    lineWidth: isHighlighted ? 2 : 1
                )
        }
    }

    private func placeholderTile(for tab: ChordCore.Tab, isHighlighted: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: [tint.opacity(isHighlighted ? 0.55 : 0.4),
                         tint.opacity(isHighlighted ? 0.25 : 0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            favicon(for: tab)
                .frame(width: 40, height: 40)
                .opacity(isHighlighted ? 1 : 0.85)
        }
    }

    @ViewBuilder
    private func favicon(for tab: ChordCore.Tab) -> some View {
        if let image = FaviconCache.shared.image(
            paneID: tab.focusedPaneID, data: tab.focusedPane.faviconData
        ) {
            image.resizable().interpolation(.high)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}