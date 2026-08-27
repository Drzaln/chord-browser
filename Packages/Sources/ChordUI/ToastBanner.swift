import AppKit
import ChordStore
import SwiftUI

/// The transient confirmation banner shown in a window's top right (non-spec:
/// user-requested) — "Zoomed to 125%", "Copied URL", and the like.
///
/// Inert feedback by default (it never swallows a click aimed at the page). When
/// the toast carries an action — "Opened in new tab", which should take you to
/// that tab — the banner becomes tappable and shows a chevron to say so.
///
/// Its capsule is the same material + Space-tint as the window's border, so it
/// reads as part of the browser chrome. `foreground` is chosen from the tint's
/// luminance so the icon and text stay readable whatever the Space's colour.
struct ToastBanner: View {
    let toast: Toast
    /// The active Space's accent, tinting the material capsule exactly like the
    /// window border (`spaceBorderTint`). `nil` leaves a plain material.
    var tint: Color?
    /// The icon/text colour, adapted to the background so it stays readable.
    var foreground: Color = .primary
    var onTap: (() -> Void)? = nil

    private var isActionable: Bool { toast.action != nil }

    var body: some View {
        Group {
            if isActionable {
                Button(action: performAction) {
                    label
                }
                .buttonStyle(.plain)
                .onHover { hovering in cursor = hovering ? .pointingHand : .arrow }
            } else {
                label
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                if let tint {
                    Capsule().fill(tint.opacity(0.4))
                }
            }
        }
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 16)
        .allowsHitTesting(isActionable)
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: toast.icon)
                .font(.system(size: 11))
                .foregroundStyle(foreground)
            Text(toast.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(foreground)
            if isActionable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(foreground.opacity(0.6))
            }
        }
    }

    private func performAction() {
        toast.action?()
    }

    @State private var cursor: NSCursor = .arrow
}
