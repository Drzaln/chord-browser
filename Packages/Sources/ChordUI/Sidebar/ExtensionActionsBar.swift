import AppKit
import ChordCore
import ChordExtensions
import ChordStore
import SwiftUI

/// The extension toolbar-action buttons in the sidebar header (M7, 7.5b, §4.7).
///
/// One button per extension loaded in the active Space. Clicking performs the
/// extension's default action — firing its click event or presenting its popup,
/// whichever the extension is configured for. The popover itself is shown inside
/// the host (it wraps a `WKWebView`), so no WebKit type reaches this view; the
/// button only hands the host an `NSView` anchor to position against (ADR 011).
struct ExtensionActionsBar: View {
    @Bindable var store: TabStore
    /// The window this view belongs to — its selection, its Space.
    @Bindable var windowState: WindowState
    let host: any ExtensionHost

    var body: some View {
        // Reading the change token here makes an action update (badge, icon,
        // enabled-ness) re-run this body and re-query `actions(in:)` (7.5a).
        _ = store.extensionActionsToken
        return content
    }

    @State private var showingPanel = false

    @ViewBuilder private var content: some View {
        if let space = store.activeSpace(in: windowState) {
            let loaded = host.loadedExtensions(in: space)
            HStack(spacing: 2) {
                ForEach(host.actions(in: space)) { action in
                    ExtensionActionButton(action: action, space: space, host: host)
                }
                // A manage button opens the per-Space panel (background-worker
                // presence + host access, 7.5d). Shown whenever anything is
                // loaded — an extension may have no toolbar action of its own.
                if !loaded.isEmpty {
                    Button { showingPanel = true } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Manage Extensions")
                    .accessibilityLabel("Manage Extensions")
                    .popover(isPresented: $showingPanel, arrowEdge: .bottom) {
                        ExtensionsPanel(store: store, windowState: windowState, host: host)
                    }
                }
            }
        }
    }
}

/// A single extension's header button.
private struct ExtensionActionButton: View {
    let action: ExtensionActionSnapshot
    let space: Space
    let host: any ExtensionHost

    var body: some View {
        Button {
            host.presentAction(slug: action.slug, in: space)
        } label: {
            icon
                .frame(width: 16, height: 16)
                .overlay(alignment: .topTrailing) { badge }
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(action.enabled ? 1 : 0.4)
        .disabled(!action.enabled)
        .help(action.label)
        .accessibilityLabel(action.label)
        // A zero-size AppKit view sits behind the button as the popover's
        // positioning anchor. Registered weakly with the host, so a removed
        // button clears itself (7.5b).
        .background(
            PopoverAnchorView { view in
                host.registerActionAnchor(view, forSlug: action.slug, in: space)
            }
        )
    }

    @ViewBuilder private var icon: some View {
        if let data = action.icon, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            // Extensions may supply no action icon; fall back to a generic mark.
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 12))
        }
    }

    @ViewBuilder private var badge: some View {
        if !action.badgeText.isEmpty {
            Text(action.badgeText)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 2)
                .padding(.vertical, 0.5)
                .background(Capsule().fill(.red))
                .offset(x: 4, y: -4)
                .fixedSize()
        }
    }
}

/// A minimal AppKit view whose only job is to be a popover anchor. It reports
/// itself to the host on creation and update; the host holds it weakly.
private struct PopoverAnchorView: NSViewRepresentable {
    let register: (NSView?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        register(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        register(nsView)
    }
}
