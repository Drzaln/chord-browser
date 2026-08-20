import ChordCore
import ChordStore
import SwiftUI

/// The floating panel's contents: the page, and just enough chrome to know
/// where you are and what the keys do (4.6).
struct LittleChordView: View {
    @Bindable var store: TabStore
    let pane: Pane
    /// The Space whose data store the page uses. `nil` → primary window's
    /// active Space.
    let spaceID: UUID?
    let promote: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ZStack {
                Color(nsColor: .textBackgroundColor)

                if let surface = store.littleChordSurface(for: pane, in: spaceID) {
                    surface.id(pane.id)
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.littleChordCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.littleChordCornerRadius, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

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
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}
