import ChordCore
import ChordExtensions
import ChordStore
import SwiftUI
import UniformTypeIdentifiers

/// The Extensions section of the settings sheet: install a `.crx`/`.xpi` from
/// disk, then enable or disable each installed extension **in the active Space**
/// (extensions are per-Space), or uninstall it everywhere.
struct ExtensionsSettings: View {
    @Bindable var store: TabStore
    /// The window this view belongs to — its selection, its Space.
    @Bindable var windowState: WindowState
    let extensions: ExtensionsService?

    @State private var installed: [InstalledExtension] = []
    @State private var enabledSlugs: Set<String> = []
    @State private var importing = false
    @State private var busySlug: String?
    @State private var errorMessage: String?
    @State private var warningMessage: String?
    /// An unverified extension whose enable toggle was flipped, awaiting a
    /// confirm. Warn-but-install: installs proceed, enables are confirmed.
    @State private var pendingEnableSlug: String?

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

            if let warningMessage {
                Label(warningMessage, systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            Text(
                store.activeSpace(in: windowState).map {
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
        .alert("Unverified extension", isPresented: Binding(
            get: { pendingEnableSlug != nil },
            set: { if !$0 { pendingEnableSlug = nil } }
        )) {
            Button("Enable Anyway") {
                if let slug = pendingEnableSlug {
                    pendingEnableSlug = nil
                    setEnabled(true, slug: slug)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingEnableSlug = nil
            }
        } message: {
            Text(
                pendingEnableSlug.map { slug in
                    let status = installed.first { $0.slug == slug }?.signatureStatus ?? .unsigned
                    return "“\(slug)” is \(Self.warningText(for: status)). Enable it only if you trust its source."
                } ?? ""
            )
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
        let untrusted = !ext.signatureStatus.isTrusted
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(.secondary)
            Text(ext.slug)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if untrusted {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(Self.warningText(for: ext.signatureStatus))
            }
            Spacer()

            if busySlug == ext.slug {
                ProgressView().controlSize(.small)
            } else {
                Toggle("Enabled", isOn: Binding(
                    get: { isEnabled },
                    set: { enable($0, slug: ext.slug, untrusted: untrusted) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(store.activeSpace(in: windowState) == nil)

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

    /// Routes an enable flip: a trusted extension enables directly, an
    /// unverified one asks first (warn-but-install). Disable never confirms.
    private func enable(_ on: Bool, slug: String, untrusted: Bool) {
        if on && untrusted {
            pendingEnableSlug = slug
        } else {
            setEnabled(on, slug: slug)
        }
    }

    /// One-line status copy for the warning icon, install message, and the
    /// enable-confirmation alert.
    static func warningText(for status: ExtensionSignatureStatus) -> String {
        switch status {
        case .trusted:
            return "signed by a trusted developer"
        case .verified:
            return "signed, but by an unknown developer"
        case .tampered:
            return "untrusted — its signature does not validate"
        case .unsigned:
            return "unsigned — no verified developer"
        case .unsupported:
            return "untrusted — its signature could not be read"
        }
    }

    // MARK: - Actions

    private func refresh() {
        guard let extensions else { return }
        installed = (try? extensions.installedExtensions()) ?? []
        if let space = store.activeSpace(in: windowState) {
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
                let installed = try extensions.install(from: url)
                errorMessage = nil
                if installed.signatureStatus.isTrusted {
                    warningMessage = nil
                } else {
                    // Warn-but-install: the bundle is in, but its unverified
                    // provenance is surfaced immediately, not hidden in a row.
                    warningMessage =
                        "“\(installed.slug)” is \(Self.warningText(for: installed.signatureStatus))."
                    + " Install only if you trust the source."
                }
                refresh()
            } catch {
                errorMessage = "Could not install: \(error.localizedDescription)"
            }
        }
    }

    private func setEnabled(_ enabled: Bool, slug: String) {
        guard let extensions, let space = store.activeSpace(in: windowState) else { return }
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
