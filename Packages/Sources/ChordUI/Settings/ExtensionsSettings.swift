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
    /// Extensions the user let into private windows.
    @State private var privateSlugs: Set<String> = []
    @State private var importing = false
    @State private var busySlug: String?
    @State private var busyStore = false
    @State private var storeLink = ""
    @State private var errorMessage: String?
    @State private var warningMessage: String?
    /// An unverified extension whose enable toggle was flipped, awaiting a
    /// confirm. Warn-but-install: installs proceed, enables are confirmed.
    @State private var pendingEnableSlug: String?
    /// What each enabled extension's scripts threw in this Space (9ba).
    @State private var scriptErrors: [String: [ExtensionScriptError]] = [:]
    @State private var errorsShownFor: String?

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

            if extensions != nil {
                HStack(spacing: 8) {
                    TextField("Chrome Web Store link or extension id", text: $storeLink)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { addFromStore() }
                    Button(busyStore ? "Adding…" : "Add") {
                        addFromStore()
                    }
                    .disabled(busyStore || Crx.id(in: storeLink) == nil)
                }
            }

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
                    $0.isPrivate
                        ? "In a private window, the switch lets an extension into private windows. Extensions stay out of them until you do."
                        : "Enabling loads the extension into “\($0.name)”. Each Space enables extensions independently."
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
        let inPrivateWindow = store.activeSpace(in: windowState)?.isPrivate == true
        let refusesPrivate = extensions?.refusesPrivate(ext) ?? false
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(ext.displayName ?? ext.slug)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let version = ext.version {
                    Text("v\(version)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !inPrivateWindow {
                    Toggle("Allow in private windows", isOn: Binding(
                        get: { privateSlugs.contains(ext.slug) },
                        set: { setAllowedInPrivate($0, slug: ext.slug) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                    .controlSize(.mini)
                    .disabled(refusesPrivate)
                    .help(refusesPrivate ? "This extension doesn't run in private windows." : "")
                }
            }
            .help(ext.identifier)
            if untrusted {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(Self.warningText(for: ext.signatureStatus))
            }
            Spacer()

            if let errors = scriptErrors[ext.slug], !errors.isEmpty {
                scriptErrorsButton(errors, slug: ext.slug)
            }

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
                .disabled(
                    store.activeSpace(in: windowState) == nil
                        || (inPrivateWindow && refusesPrivate)
                )
                .help(inPrivateWindow && refusesPrivate
                    ? "This extension doesn't run in private windows." : "")

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

    /// The extension's script errors, behind a count: what to look at when an
    /// extension silently stops working.
    private func scriptErrorsButton(_ errors: [ExtensionScriptError], slug: String) -> some View {
        Button {
            refresh()
            errorsShownFor = slug
        } label: {
            Label(
                errors.count == 1 ? "1 script error" : "\(errors.count) script errors",
                systemImage: "exclamationmark.bubble"
            )
            .font(.system(size: 10))
            .foregroundStyle(.orange)
        }
        .buttonStyle(.borderless)
        .help("Exceptions and rejections in this extension's scripts since it loaded")
        .popover(isPresented: Binding(
            get: { errorsShownFor == slug },
            set: { if !$0 { errorsShownFor = nil } }
        )) {
            let shown = scriptErrors[slug] ?? errors
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(shown) { error in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(error.message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                if error.count > 1 {
                                    Text("×\(error.count)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        shown.map(\.message).joined(separator: "\n"), forType: .string
                    )
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(width: 420)
        }
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
        privateSlugs = Set(installed.map(\.slug).filter { extensions.isAllowedInPrivate(slug: $0) })
        if let space = store.activeSpace(in: windowState) {
            enabledSlugs = Set(extensions.enabledExtensions(in: space).map(\.slug))
            scriptErrors = Dictionary(uniqueKeysWithValues: enabledSlugs.map {
                ($0, extensions.scriptErrors(slug: $0, in: space))
            })
        } else {
            enabledSlugs = []
            scriptErrors = [:]
        }
    }

    private func addFromStore() {
        guard let extensions, let id = Crx.id(in: storeLink) else { return }
        busyStore = true
        errorMessage = nil
        Task {
            do {
                let installed = try await extensions.installFromStore(id: id)
                storeLink = ""
                if let space = store.activeSpace(in: windowState) {
                    try await extensions.enable(slug: installed.slug, in: space)
                }
                refresh()
            } catch ExtensionsServiceError.declined {
                // Cancelled in the install question.
            } catch {
                errorMessage = "Could not add from the store: \(error.localizedDescription)"
            }
            busyStore = false
        }
    }

    private func handleImport(_ result: Result<[URL], any Error>) {
        guard let extensions else { return }
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                // A file chosen from outside the app is security-scoped; the
                // installer reads it into staging first thing, but the install
                // question comes in between, so access spans the whole call.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let installed = try await extensions.install(from: url)
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
                } catch ExtensionsServiceError.declined {
                    // Cancelled in the install question: nothing to report.
                } catch {
                    errorMessage = "Could not install: \(error.localizedDescription)"
                }
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

    private func setAllowedInPrivate(_ allowed: Bool, slug: String) {
        guard let extensions else { return }
        Task {
            await extensions.setAllowedInPrivate(allowed, slug: slug, spaces: store.spaces)
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
