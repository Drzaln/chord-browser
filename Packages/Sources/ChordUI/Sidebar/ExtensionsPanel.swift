import ChordCore
import ChordExtensions
import ChordStore
import SwiftUI

/// A small management panel for the extensions loaded in the active Space
/// (M7, 7.5d). Surfaces §6.6's per-Space cost — which extensions run a
/// background worker (one process *per Space*) — and the host-access control a
/// required-`host_permissions` extension needs, since WebKit does not prompt for
/// it (the 7.5c live finding). Real memory is deferred: no WKWebExtension API
/// exposes per-process memory.
struct ExtensionsPanel: View {
    @Bindable var store: TabStore
    /// The window this view belongs to — its selection, its Space.
    @Bindable var windowState: WindowState
    let host: any ExtensionHost

    private var space: Space? { store.activeSpace(in: windowState) }
    private var extensions: [LoadedExtension] {
        space.map { host.loadedExtensions(in: $0) } ?? []
    }
    private var backgroundWorkerCount: Int {
        extensions.filter(\.hasBackgroundContent).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extensions")
                .font(.system(size: 13, weight: .semibold))

            if extensions.isEmpty {
                Text("No extensions loaded in this Space.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(extensions) { ext in
                        row(for: ext)
                    }
                }
                Divider()
                Text(
                    "\(backgroundWorkerCount) of \(extensions.count) run a background worker in this Space"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder private func row(for ext: LoadedExtension) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(.secondary)
                Text(ext.displayName ?? ext.slug)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }

            if ext.hasBackgroundContent {
                Label(
                    ext.hasPersistentBackgroundContent
                        ? "Persistent background worker" : "Background worker (on demand)",
                    systemImage: "bolt.fill"
                )
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            }

            if let space {
                Toggle(
                    "Access on all sites",
                    isOn: Binding(
                        get: { host.hasAllHostsAccess(slug: ext.slug, in: space) },
                        set: { host.setAllHostsAccess($0, slug: ext.slug, in: space) }
                    )
                )
                .font(.system(size: 11))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
    }
}
