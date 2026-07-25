import BrowserCore
import BrowserExtensions
import BrowserStore
import SwiftUI
import UniformTypeIdentifiers

/// The Extensions section of the settings sheet: install a `.crx`/`.xpi` from
/// disk, then enable or disable each installed extension **in the active Space**
/// (extensions are per-Space), or uninstall it everywhere.
struct ExtensionsSettings: View {
    @Bindable var store: TabStore
    let extensions: ExtensionsService?

    @State private var installed: [InstalledExtension] = []
    @State private var enabledSlugs: Set<String> = []
    @State private var importing = false
    @State private var busySlug: String?
    @State private var errorMessage: String?

    /// `.crx`/`.xpi` are not registered UTTypes; a dynamic type from the
    /// extension still lets the panel show those files, with a ZIP fallback.
    private static let allowedTypes: [UTType] = [
        UTType(filenameExtension: "crx"),
        UTType(filenameExtension: "xpi"),
        .zip,
    ].compactMap { $0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if extensions == nil {
                Text("The extension subsystem is not available.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if installed.isEmpty {
                Text("No extensions installed. Add a .crx or .xpi to get started.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(installed) { row(for: $0) }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            Text(
                store.activeSpace.map {
                    "Enabling loads the extension into “\($0.name)”. Each Space enables extensions independently."
                } ?? "Open a Space to enable extensions."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .task { refresh() }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: Self.allowedTypes.isEmpty ? [.item] : Self.allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    private var header: some View {
        HStack {
            Text("Extensions").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                errorMessage = nil
                importing = true
            } label: {
                Label("Add Extension…", systemImage: "plus")
            }
            .disabled(extensions == nil)
        }
    }

    @ViewBuilder
    private func row(for ext: InstalledExtension) -> some View {
        let isEnabled = enabledSlugs.contains(ext.slug)
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(.secondary)
            Text(ext.slug)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()

            if busySlug == ext.slug {
                ProgressView().controlSize(.small)
            } else {
                Toggle("Enabled", isOn: Binding(
                    get: { isEnabled },
                    set: { setEnabled($0, slug: ext.slug) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(store.activeSpace == nil)

                Button(role: .destructive) {
                    remove(slug: ext.slug)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Uninstall")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    // MARK: - Actions

    private func refresh() {
        guard let extensions else { return }
        installed = (try? extensions.installedExtensions()) ?? []
        if let space = store.activeSpace {
            enabledSlugs = Set(extensions.enabledExtensions(in: space).map(\.slug))
        } else {
            enabledSlugs = []
        }
    }

    private func handleImport(_ result: Result<[URL], any Error>) {
        guard let extensions else { return }
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            // A file chosen from outside the app is security-scoped; the
            // installer copies it into the library, so access only needs to
            // span that copy.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try extensions.install(from: url)
                errorMessage = nil
                refresh()
            } catch {
                errorMessage = "Could not install: \(error.localizedDescription)"
            }
        }
    }

    private func setEnabled(_ enabled: Bool, slug: String) {
        guard let extensions, let space = store.activeSpace else { return }
        busySlug = slug
        Task {
            do {
                if enabled {
                    try await extensions.enable(slug: slug, in: space)
                } else {
                    try await extensions.disable(slug: slug, in: space)
                }
                errorMessage = nil
            } catch {
                errorMessage = "Could not \(enabled ? "enable" : "disable"): \(error.localizedDescription)"
            }
            busySlug = nil
            refresh()
        }
    }

    private func remove(slug: String) {
        guard let extensions else { return }
        busySlug = slug
        Task {
            do {
                try await extensions.remove(slug: slug, from: store.spaces)
                errorMessage = nil
            } catch {
                errorMessage = "Could not uninstall: \(error.localizedDescription)"
            }
            busySlug = nil
            refresh()
        }
    }
}
