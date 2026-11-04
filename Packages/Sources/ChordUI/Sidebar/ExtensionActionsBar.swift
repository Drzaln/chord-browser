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
    /// Told when the manage panel opens and closes, so a parent that shows
    /// this row only under the pointer keeps it (and the panel's anchor) while
    /// the panel is up.
    var onPanelShown: (Bool) -> Void = { _ in }
    /// How many buttons fit beside the address (21n). Pinned ones past it are
    /// reached from the Manage Extensions panel, like unpinned ones, so the
    /// field always keeps room for the address.
    var maxButtons: Int = .max

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
            let actions = ExtensionToolbarLayout.shown(
                host.actions(in: space), pins: store.extensionPins, limit: maxButtons
            )
            HStack(spacing: 2) {
                ForEach(actions) { action in
                    ExtensionActionButton(
                        action: action, space: space, host: host, pins: store.extensionPins
                    )
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
                        ExtensionsPanel(
                            store: store, windowState: windowState, host: host,
                            run: { slug in
                                // The panel's popover goes first: an extension
                                // popup shown while it is up would be closed by
                                // its dismissal. The popup then hangs from the
                                // manager anchor, as any button-less one does.
                                showingPanel = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    host.presentAction(slug: slug, in: space)
                                }
                            }
                        )
                    }
                    .background(
                        PopoverAnchorView { view in
                            host.registerActionAnchor(
                                view, forSlug: WebKitExtensionHost.managerAnchorSlug,
                                in: space
                            )
                        }
                    )
                }
            }
            // Rebuild the row when the loaded set changes. Without this,
            // SwiftUI can keep the button created for one extension while its
            // icon updates to another, so the Loom icon opened Bitwarden.
            .id((actions.map(\.id) + ["loaded:\(loaded.count)"]).joined(separator: "|"))
            .onChange(of: showingPanel) { _, shown in
                guard !shown else { return onPanelShown(true) }
                // Released a beat late: the panel's Open closes it and then
                // shows the extension's popup, and a floating sidebar that
                // retracted in between would take the popup's anchor with it.
                // By now the popup holds the sidebar itself.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !showingPanel { onPanelShown(false) }
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
    let pins: ExtensionPinning?

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
        .contextMenu {
            if let pins {
                Button("Unpin from Address Bar") { pins.setPinned(false, slug: action.slug) }
            }
        }
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

/// Which extension buttons the address field shows, and how many fit (21n).
@MainActor
enum ExtensionToolbarLayout {
    /// A 24 pt button plus the bar's 2 pt spacing.
    static let slotWidth: CGFloat = 26
    /// What the address keeps however many extensions are pinned.
    static let minimumAddressWidth: CGFloat = 96
    /// The Manage Extensions button, the saved-login button's slot, and the
    /// row's trailing padding — present (or reserved) whatever is pinned.
    static let reservedWidth: CGFloat = slotWidth * 2 + 6

    /// How many extension buttons fit in an address row this wide.
    static func buttonCount(fitting rowWidth: CGFloat) -> Int {
        let room = rowWidth - minimumAddressWidth - reservedWidth
        return room > 0 ? Int(room / slotWidth) : 0
    }

    /// The pinned actions, in their usual order, up to `limit`. Without a
    /// pinning store every action counts as pinned (tests, previews).
    static func shown(
        _ actions: [ExtensionActionSnapshot], pins: ExtensionPinning?, limit: Int
    ) -> [ExtensionActionSnapshot] {
        let pinned = pins.map { pins in actions.filter { pins.isPinned($0.slug) } } ?? actions
        return Array(pinned.prefix(max(0, limit)))
    }
}

/// A minimal AppKit view whose only job is to be a popover anchor. It reports
/// itself to the host on creation and update; the host holds it weakly.
struct PopoverAnchorView: NSViewRepresentable {
    let register: (NSView?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        register(view)
        return view
    }

    // Deliberately not re-registered from `updateNSView`, as in Search: the
    // outgoing layout can still update during a transition, and must not
    // replace the new layout's anchor with a view about to disappear.
    func updateNSView(_ nsView: NSView, context: Context) {}
}
