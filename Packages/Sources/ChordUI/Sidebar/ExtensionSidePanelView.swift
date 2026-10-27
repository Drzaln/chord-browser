import AppKit
import ChordCore
import ChordExtensions
import ChordStore
import SwiftUI

/// A docked extension side panel (M9b): an extension's `sidePanel.html` beside
/// the page, kept in the window rather than opened as a tab.
///
/// The page itself belongs to the extension host; this view only frames it and
/// closes it. Opening again with another URL reuses the same page, so an
/// extension's panel keeps its state while it moves between tabs.
struct ExtensionSidePanelView: View {
    @Bindable var store: TabStore
    @Bindable var windowState: WindowState
    let host: (any ExtensionHost)?
    let panel: WindowState.ExtensionSidePanelState

    private var space: Space? {
        store.spaces.first { $0.id == panel.spaceID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(panel.slug)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Close Side Panel")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.bar)
            Divider()
            if let space, let view = host?.sidePanelView(
                slug: panel.slug, url: panel.url, in: space
            ) {
                SidePanelWebView(view: view)
            } else {
                Text("This extension's side panel could not be opened.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func close() {
        if let space { host?.closeSidePanel(slug: panel.slug, in: space) }
        windowState.closeExtensionPanel()
    }
}

private struct SidePanelWebView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
