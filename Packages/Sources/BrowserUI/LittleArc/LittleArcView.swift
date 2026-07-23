import BrowserCore
import BrowserStore
import SwiftUI

/// The floating panel's contents: the page, and just enough chrome to know
/// where you are and what the keys do (4.6).
struct LittleArcView: View {
    @Bindable var store: TabStore
    let pane: Pane
    let promote: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ZStack {
                Color(nsColor: .textBackgroundColor)

                if let surface = store.littleArcSurface(for: pane) {
                    surface.id(pane.id)
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.littleArcCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.littleArcCornerRadius, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.forward.app")
                .foregroundStyle(.secondary)

            // The live URL, not the one it opened with — the panel is browsable.
            Text(store.runtime(for: pane.id).currentURL?.host() ?? pane.url.host() ?? "")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            Button(action: promote) {
                HStack(spacing: 4) {
                    Text("Open as Tab")
                    Text("⌘O").foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}
