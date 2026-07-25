import BrowserCore
import BrowserStore
import SwiftUI

/// The Peek preview's contents: a small live view of the hovered link, with a
/// hint at the bottom (non-spec: user-requested). No controls — Peek is a
/// glance; the panel ignores the mouse entirely.
struct PeekView: View {
    @Bindable var store: TabStore
    let pane: Pane

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .textBackgroundColor)
                if let surface = store.littleArcSurface(for: pane) {
                    surface.id(pane.id)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "eye").font(.system(size: 9))
                Text(store.runtime(for: pane.id).currentURL?.host() ?? pane.url.host() ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Release ⌘ to dismiss")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.regularMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.littleArcCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.littleArcCornerRadius, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }
}
