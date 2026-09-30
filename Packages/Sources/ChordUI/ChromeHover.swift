import SwiftUI

/// A uniform hover highlight for the window's chrome controls — toolbar buttons,
/// the address bar, the Space switcher, folder and section headers, command-bar
/// rows. The tab rows draw their own (they also track selection), but everything
/// else uses this so the pointer reads the same everywhere.
struct HoverHighlight: ViewModifier {
    /// The fill behind the pointer. The active Space's accent for sidebar
    /// controls; `.primary` (a faint grey) for the toolbar.
    var tint: Color = .primary
    var cornerRadius: CGFloat = 6
    var activeOpacity: Double = 0.12
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(isHovering ? activeOpacity : 0))
            }
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// Draws `HoverHighlight`'s tinted background while the pointer is over the
    /// view. Sits after any padding so it spans the same row width a tab's does.
    func hoverHighlight(
        tint: Color = .primary, cornerRadius: CGFloat = 6, opacity: Double = 0.12
    ) -> some View {
        modifier(HoverHighlight(tint: tint, cornerRadius: cornerRadius, activeOpacity: opacity))
    }
}
