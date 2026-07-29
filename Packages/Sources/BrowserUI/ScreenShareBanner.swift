import SwiftUI

/// The "you are sharing this window" banner (non-spec: user-requested).
///
/// WebKit exposes no screen-capture state, so whether a page is screen-sharing
/// is observed in the page itself (see `ScreenShareMonitor`) and surfaced on the
/// pane's runtime. This banner makes that state impossible to forget — sharing
/// is easy to leave running after a call — and gives a one-click way to stop it
/// without hunting through the site's own UI.
struct ScreenShareBanner: View {
    /// Stops every display-capture track the page has open.
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating)

            Text("Sharing this window")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            Button(action: onStop) {
                Text("Stop")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.red.opacity(0.92), in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sharing this window")
        .accessibilityHint("Activate Stop to end screen sharing")
    }
}
