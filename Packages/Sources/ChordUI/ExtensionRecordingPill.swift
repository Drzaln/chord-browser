import ChordExtensions
import SwiftUI

/// "● Loom is recording your screen — Stop" (1mm.15), ported from Search's
/// RecordingIndicator: one line per extension recording through the capture
/// bridge, at the foot of the window, while it records. The Mac's own
/// sharing item says that something records; this says which extension, and
/// stops it without hunting through the extension's own UI.
struct ExtensionRecordingPill: View {
    let recordings: [ExtensionRecording]
    let onStop: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(recordings) { recording in
                HStack(spacing: 8) {
                    // A recording is known at a glance by its red dot, as in
                    // Chrome and Loom.
                    Circle()
                        .fill(Color(nsColor: .systemRed))
                        .frame(width: 7, height: 7)
                    (Text(recording.name).font(.system(size: 12, weight: .semibold))
                        + Text(" \(recording.what)").font(.system(size: 12)))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 12)
                    Button { onStop(recording.id) } label: {
                        Text("Stop")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .padding(.horizontal, 11)
                            .frame(height: 22)
                            .background(.primary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop \(recording.name)")
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording")
    }
}
