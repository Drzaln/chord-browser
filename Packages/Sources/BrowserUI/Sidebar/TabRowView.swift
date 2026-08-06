import BrowserCore
import SwiftUI

/// One sidebar row. Deliberately cheap: no image decoding, no string
/// formatting, no colour computation in `body` (6.4).
struct TabRowView: View {
    // Fully qualified: SwiftUI ships its own `Tab` type on macOS 15.
    let tab: BrowserCore.Tab
    let isSelected: Bool
    /// The active Space's colour, so a tab's highlight reads as part of the
    /// Space rather than the generic system selection (item 1).
    var tint: Color = .accentColor
    /// Live audio state for the mute affordance (non-spec: user-requested).
    var isPlayingAudio: Bool = false
    var isMuted: Bool = false
    /// When the tab's sleep timer fires, if one is armed (non-spec:
    /// user-requested).
    var sleepTimerDeadline: Date? = nil
    let select: () -> Void
    let close: () -> Void
    var toggleMute: () -> Void = {}
    var cancelSleepTimer: () -> Void = {}
    let beginDrag: () -> Void
    let endDrag: () -> Void

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

            // Mute toggle — shown whenever the tab is making noise or is muted,
            // so a muted tab still offers the way back (non-spec: user-requested).
            if isPlayingAudio || isMuted {
                Button(action: toggleMute) {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
                .buttonStyle(.plain)
                .help(isMuted ? "Unmute tab" : "Mute tab")
                .accessibilityLabel(isMuted ? "Unmute tab" : "Mute tab")
            }

            // Sleep timer indicator — shown while armed; clicking cancels it
            // (non-spec: user-requested).
            if let sleepTimerDeadline {
                Button(action: cancelSleepTimer) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Sleep timer: \(Self.remainingText(until: sleepTimerDeadline)) — click to cancel")
                .accessibilityLabel("Cancel sleep timer")
            }

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
        // Handles the click in the region it covers; this catches the rest.
        .onTapGesture(perform: select)
        // Drag a row into the content area to split the tab it lands on (4.5).
        //
        // An AppKit drag source rather than `onDrag`, because `onDrag`'s
        // payload arrives at the destination empty — see `TabDragSource`. It
        // sits *above* the row, so it takes the click too, and stops short of
        // the close button so that stays clickable.
        .overlay {
            TabDragSource(
                tabID: tab.id,
                title: tab.displayTitle,
                onDragBegan: beginDrag,
                onDragEnded: endDrag,
                onClick: select
            )
            // The gap keeps the trailing buttons clickable — wider when a mute
            // or sleep-timer button shares the row with the close button.
            .padding(.trailing, hasTrailingButtons
                ? Metrics.sidebarRowHeight + 20
                : Metrics.sidebarRowHeight)
        }
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
        // Tinted with the Space colour rather than the system selection, so a
        // selected tab matches the Space's gradient (item 1).
        if isSelected {
            shape.fill(tint.opacity(0.40))
        } else if isHovering {
            shape.fill(tint.opacity(0.18))
        } else {
            shape.fill(.clear)
        }
    }

    /// Whether any trailing button shares the row with the close button, so the
    /// drag source's right-hand gap stays wide enough to keep them clickable.
    private var hasTrailingButtons: Bool {
        isPlayingAudio || isMuted || sleepTimerDeadline != nil
    }

    /// "23 min", "1 h 4 min", or "<1 min" for the indicator's tooltip. Rendered
    /// on hover only, so the per-body cost stays off the cheap row path (6.4).
    private static func remainingText(until deadline: Date) -> String {
        let total = Int(ceil(deadline.timeIntervalSinceNow / 60))
        if total <= 0 { return "<1 min" }
        if total < 60 { return "\(total) min" }
        return "\(total / 60) h \(total % 60) min"
    }
}
