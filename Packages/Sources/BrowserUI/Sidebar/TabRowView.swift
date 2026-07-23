import BrowserCore
import SwiftUI

/// One sidebar row. Deliberately cheap: no image decoding, no string
/// formatting, no colour computation in `body` (6.4).
struct TabRowView: View {
    // Fully qualified: SwiftUI ships its own `Tab` type on macOS 15.
    let tab: BrowserCore.Tab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            favicon
                .frame(width: Metrics.faviconSize, height: Metrics.faviconSize)

            Text(tab.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 12))

            Spacer(minLength: 0)

            if isHovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.sidebarRowHeight)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering in
            withAnimation(Motion.respectingReduceMotion(
                Motion.sidebarHover, reduceMotion: reduceMotion
            )) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var favicon: some View {
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

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if isSelected {
            shape.fill(.selection)
        } else if isHovering {
            shape.fill(.quaternary)
        } else {
            shape.fill(.clear)
        }
    }
}
