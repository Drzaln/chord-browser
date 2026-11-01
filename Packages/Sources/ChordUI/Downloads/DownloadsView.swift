import ChordCore
import ChordStore
import SwiftUI

/// Downloads popover, opened from the toolbar (M4).
///
/// Only shown once something has been downloaded — an always-visible empty
/// button is noise in a browser this small.
struct DownloadsButton: View {
    @Bindable var downloads: DownloadsStore
    /// This window's state. The popover's presentation lives here rather than in
    /// local `@State` so the sidebar can be held open while it shows — the
    /// button is in the sidebar header, so an auto-hide would remove the anchor
    /// and close the popover (see `WindowState.isSidebarHeldOpen`).
    @Bindable var windowState: WindowState

    /// At the leading end of the sidebar's bottom bar, always there (as Arc
    /// keeps its own), so the Space switcher beside it stays centred.
    var body: some View {
        Button {
            windowState.isDownloadsPopoverOpen.toggle()
        } label: {
            Image(systemName: downloads.activeCount > 0
                ? "arrow.down.circle.fill"
                : "arrow.down.circle")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(downloads.activeCount > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .hoverHighlight(opacity: 0.12)
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .popover(isPresented: $windowState.isDownloadsPopoverOpen, arrowEdge: .top) {
            DownloadsList(downloads: downloads)
        }
    }
}

struct DownloadsList: View {
    @Bindable var downloads: DownloadsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Downloads")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            if !downloads.hasDownloads {
                Text("No downloads")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(downloads.downloads) { item in
                        DownloadRow(
                            item: item,
                            cancel: { downloads.cancel(item.id) },
                            clear: { downloads.clear(item.id) }
                        )
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 320)
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    let cancel: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)

                switch item.state {
                case .inProgress:
                    // A server that sends no Content-Length gives no fraction,
                    // and a determinate bar pinned at zero reads as a hang.
                    if let fraction = item.fractionCompleted {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .finished:
                    Text("Completed — \(byteText(item.bytesReceived))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .failed(let message, _):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)

                case .cancelled:
                    Text("Cancelled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if item.isActive {
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Cancel")
            } else {
                Button(action: clear) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Remove from list")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var status: String {
        item.bytesExpected > 0
            ? "\(byteText(item.bytesReceived)) of \(byteText(item.bytesExpected))"
            : byteText(item.bytesReceived)
    }

    private func byteText(_ count: Int64) -> String {
        ByteCountFormatStyle(style: .file).format(count)
    }
}
