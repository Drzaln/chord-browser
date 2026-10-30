import ChordCore
import ChordExtensions
import ChordLogging
import Foundation

public enum ExtensionsServiceError: Error, CustomStringConvertible {
    case notInstalled(String)
    case refusesPrivate(String)
    /// The user said no to the install question. Nothing was installed, and
    /// nothing needs saying.
    case declined(String)
    public var description: String {
        switch self {
        case .declined(let name): "\(name) was not added"
        case .notInstalled(let slug): "no installed extension with slug \(slug)"
        case .refusesPrivate(let slug): "\(slug) does not run in private windows"
        }
    }
}

/// Coordinates the three parts of the extension subsystem the app drives
/// (M7, 7.4): the on-disk library (`ExtensionInstaller`), the per-Space host
/// (`ExtensionHost`), and the enablement store (`ExtensionEnablementRepository`).
///
/// WebKit-free at its surface — it deals in slugs, `Space`s, `InstalledExtension`
/// and `LoadedExtension` — so it lives in `ChordStore` and needs no WebKit
/// import. Enable is load + persist; disable is unload + persist; and on launch
/// `restoreEnabled` re-loads whatever was on before the last quit in the Spaces
/// on screen, and `ensureLoaded` the rest when a window first shows them.
@MainActor
public final class ExtensionsService {
    private let installer: ExtensionInstaller
    private let host: any ExtensionHost
    private let enablement: any ExtensionEnablementRepository
    private let log = AppLog.category("extensions")

    /// Fired after a store update attempt, so the UI can say what changed.
    /// WebKit-free: a plain human-readable line.
    public var onStoreUpdate: (@MainActor (String) -> Void)?

    /// Where "allowed in private windows" is kept, per extension.
    private let preferences: any PreferenceStore

    public init(
        installer: ExtensionInstaller,
        host: any ExtensionHost,
        enablement: any ExtensionEnablementRepository,
        preferences: any PreferenceStore = UserDefaults.standard
    ) {
        self.installer = installer
        self.host = host
        self.enablement = enablement
        self.preferences = preferences
    }

    // MARK: - Private windows

    private static func privateKey(_ slug: String) -> String {
        "extensions.private.\(slug)"
    }

    /// Whether the user let this extension into private windows. Off until they
    /// do, as in Chrome. A private Space has no enablement records of its own
    /// (it is gone when its window closes), so this is what it runs.
    public func isAllowedInPrivate(slug: String) -> Bool {
        preferences.object(forKey: Self.privateKey(slug)) as? Bool ?? false
    }

    /// Whether the extension's manifest keeps it out of private windows
    /// (`"incognito": "not_allowed"`), whatever the user allowed.
    public func refusesPrivate(_ installed: InstalledExtension) -> Bool {
        ExtensionBundle.refusesPrivate(at: installed.resourceURL)
    }

    /// Lets the extension into private windows, or takes it out, including the
    /// private Spaces open right now.
    public func setAllowedInPrivate(_ allowed: Bool, slug: String, spaces: [Space]) async {
        preferences.set(allowed, forKey: Self.privateKey(slug))
        for space in spaces where space.isPrivate && loadedSpaces.contains(space.id) {
            let isLoaded = host.loadedExtensions(in: space).contains { $0.slug == slug }
            if allowed, !isLoaded {
                await loadIntoPrivate(slug: slug, space: space)
            } else if !allowed, isLoaded {
                try? host.unload(slug: slug, in: space)
            }
        }
    }

    private func loadIntoPrivate(slug: String, space: Space) async {
        guard let found = try? installer.installedExtensions().first(where: { $0.slug == slug }),
            !refusesPrivate(found)
        else { return }
        let installed = installer.prepareIfNeeded(found)
        _ = try? await host.load(installed, in: space)
    }

    public func installedExtensions() throws -> [InstalledExtension] {
        try installer.installedExtensions()
    }

    public func enabledExtensions(in space: Space) -> [LoadedExtension] {
        host.loadedExtensions(in: space)
    }

    /// The extension enabled in the Space that took over saving passwords, by
    /// name, or nil while Chord should offer to save as usual.
    public func passwordSavingTakenBy(in space: Space) -> String? {
        host.loadedExtensions(in: space)
            .first { host.turnedOffPasswordSaving(identifier: $0.identifier, in: space) }
            .map { $0.displayName ?? $0.slug }
    }

    /// The default toolbar-action snapshots for the extensions loaded in a Space
    /// (7.5a), sorted by slug. WebKit-free values the sidebar header renders.
    public func actions(in space: Space) -> [ExtensionActionSnapshot] {
        host.actions(in: space)
    }

    /// Asks what an install (or an update that wants more) may do, before
    /// anything of it is in the library. The app shows a sheet on the browser
    /// window (`ExtensionConsent.ask`); tests answer directly. Nil installs
    /// without asking and records no consent, so such an install still asks
    /// for site access when it is enabled.
    public var askToInstall: (@MainActor (ExtensionConsentQuestion) async -> Bool)?

    @discardableResult
    public func install(from url: URL) async throws -> InstalledExtension {
        try await admit(installer.stage(
            data: Data(contentsOf: url), sourceName: url.lastPathComponent, sourceURL: url
        ))
    }

    /// Asks, then commits or discards a staged bundle. What it asks for is
    /// written down as consented, so later updates can be compared to it and
    /// its sites granted at load (the consent covers them).
    private func admit(_ staged: ExtensionInstaller.Staged) async throws -> InstalledExtension {
        guard let askToInstall else { return try installer.commit(staged, consented: nil) }
        let name = staged.displayName ?? staged.slug
        let grants = await ExtensionConsent.grants(of: staged.resourceURL)
        let question = await ExtensionConsent.question(for: staged.resourceURL, name: name)
        guard await askToInstall(question) else {
            installer.discard(staged)
            throw ExtensionsServiceError.declined(name)
        }
        return try installer.commit(staged, consented: grants)
    }

    /// Download a Chrome Web Store extension, verify its CRX3 signature, and
    /// add it to the library. It is not enabled in any Space until the caller
    /// asks; the Settings row and the per-Space switch stay in control.
    @discardableResult
    public func installFromStore(id: String) async throws -> InstalledExtension {
        let data = try await Crx.fetch(id)
        let installed = try await admit(installer.stage(
            data: data, sourceName: "\(id).crx", fromStore: true
        ))
        log.notice(
            "installed store extension \(installed.slug) as \(installed.identifier)"
        )
        return installed
    }

    /// Loads the extension into the Space and records it as enabled. Persists
    /// only after the load succeeds, so a bundle that fails to load is not left
    /// marked on.
    public func enable(slug: String, in space: Space) async throws {
        // A private Space keeps no records: enabling there is allowing the
        // extension into private windows.
        if space.isPrivate {
            guard let found = try installer.installedExtensions().first(where: { $0.slug == slug })
            else { throw ExtensionsServiceError.notInstalled(slug) }
            guard !refusesPrivate(found) else { throw ExtensionsServiceError.refusesPrivate(slug) }
            await setAllowedInPrivate(true, slug: slug, spaces: [space])
            if !loadedSpaces.contains(space.id) { await loadIntoPrivate(slug: slug, space: space) }
            return
        }
        guard let found = try installer.installedExtensions().first(where: { $0.slug == slug })
        else { throw ExtensionsServiceError.notInstalled(slug) }
        let installed = installer.prepareIfNeeded(found)
        try await host.load(installed, in: space)
        try await enablement.setEnabled(true, slug: slug, spaceID: space.id)
        // Its manifest sites were granted as it loaded, in this Space as in
        // any other (Chrome-style: installing it was the yes). Nothing to ask.
    }

    public func disable(slug: String, in space: Space) async throws {
        if space.isPrivate {
            preferences.set(false, forKey: Self.privateKey(slug))
            try host.unload(slug: slug, in: space)
            return
        }
        try host.unload(slug: slug, in: space)
        try await enablement.setEnabled(false, slug: slug, spaceID: space.id)
    }

    /// Uninstalls an extension: disables it in every Space it might be loaded in
    /// (best-effort — a Space where it was never on simply no-ops), then deletes
    /// the bundle from the on-disk library. After this the slug is gone
    /// everywhere, including from the enablement records.
    public func remove(slug: String, from spaces: [Space]) async throws {
        for space in spaces {
            try? await disable(slug: slug, in: space)
        }
        // What it kept goes with it, as in Chrome: installed again, it starts
        // from nothing. Bitwarden reinstalled over its old storage drew an
        // empty popup.
        let identifier = ((try? installer.installedExtensions()) ?? [])
            .first { $0.slug == slug }?.identifier
        if let identifier {
            await host.forgetData(identifier: identifier, in: spaces.filter { !$0.isPrivate })
        }
        try installer.remove(slug: slug)
        preferences.set(nil, forKey: Self.privateKey(slug))
    }

    /// Ask the Chrome Web Store whether any installed store extension has a
    /// newer version; install and reload the ones that do. Best-effort: a
    /// network or parse failure is logged, never a launch failure.
    public func updateStoreExtensions(in spaces: [Space]) async {
        guard let installed = try? installer.installedExtensions() else { return }
        for item in installed where item.fromStore {
            guard let current = item.version,
                  let newer = await newerVersion(for: item.identifier),
                  // An older build recorded `.unsupported` for every store CRX3
                  // (the verifier read a field Chrome does not write). Reinstall
                  // even at the same version so the sidecar tells the truth.
                  newer != current || item.signatureStatus == .unsupported
            else { continue }
            do {
                let data = try await Crx.fetch(item.identifier)
                let staged = try installer.stage(
                    data: data, sourceName: "\(item.identifier).crx", fromStore: true
                )
                guard let updated = try await admitUpdate(staged, replacing: item) else {
                    log.notice("kept \(item.slug) at \(current): the update wants more access")
                    continue
                }
                for space in spaces
                where host.loadedExtensions(in: space).contains(where: {
                    $0.slug == item.slug
                }) {
                    try? host.unload(slug: item.slug, in: space)
                    _ = try? await host.load(updated, in: space)
                }
                log.notice(
                    "updated store extension \(item.slug) from \(current) to \(newer)"
                )
                let label = updated.displayName ?? item.displayName ?? item.slug
                onStoreUpdate?(
                    newer != current
                        ? "Updated \(label) to \(newer)"
                        : "Verified \(label)"
                )
            } catch {
                log.error(
                    "update of \(item.slug) failed: \(String(describing: error))"
                )
            }
        }
    }

    /// An update asks again only when it wants more than was agreed to; told
    /// no, the old version stays (nil). An install from before install consent
    /// is compared with what its current version asks for, and stays without a
    /// consent record unless the user is asked now.
    func admitUpdate(
        _ staged: ExtensionInstaller.Staged, replacing item: InstalledExtension
    ) async throws -> InstalledExtension? {
        guard let askToInstall else { return try installer.commit(staged, consented: item.consentedGrants) }
        let grants = await ExtensionConsent.grants(of: staged.resourceURL)
        let agreed: [String]
        if let consented = item.consentedGrants {
            agreed = consented
        } else {
            agreed = await ExtensionConsent.grants(of: item.resourceURL)
        }
        guard !Set(grants).isSubset(of: agreed) else {
            return try installer.commit(staged, consented: item.consentedGrants == nil ? nil : grants)
        }
        let question = await ExtensionConsent.question(
            for: staged.resourceURL, name: staged.displayName ?? item.displayName ?? item.slug,
            updating: true
        )
        guard await askToInstall(question) else {
            installer.discard(staged)
            return nil
        }
        return try installer.commit(staged, consented: grants)
    }

    private func newerVersion(for id: String) async -> String? {
        var parts = URLComponents(
            string: "https://clients2.google.com/service/update2/crx"
        )!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "updatecheck"),
            URLQueryItem(name: "prodversion", value: Crx.chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc"),
        ]
        guard let url = parts.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8),
              let check = xml.range(
                of: #"<updatecheck\b[^>]*>"#, options: .regularExpression
              ).map({ String(xml[$0]) }),
              check.contains("status=\"ok\""),
              let version = check.range(
                of: #"\bversion="([^"]+)""#, options: .regularExpression
              ).map({ String(check[$0].dropFirst(9).dropLast()) })
        else { return nil }
        return version
    }

    /// The Spaces whose enabled extensions have been loaded (or are loading)
    /// this session. A Space no window has shown is not in here, and has started
    /// no extension workers.
    private var loadedSpaces: Set<UUID> = []

    /// Re-loads the enabled extensions of the Spaces on screen once the store has
    /// restored its Spaces. The others wait for `ensureLoaded(space:)`, when a
    /// window first shows them: N Spaces × M extensions would otherwise be N×M
    /// background workers (and native hosts like Bitwarden's desktop_proxy) for
    /// Spaces the user may not open all session.
    public func restoreEnabled(spaces: [Space], active: [Space]) async {
        // A wipe the last run didn't finish goes first, so nothing loads over
        // a removed extension's old data.
        await host.forgetLeftOver(in: spaces.filter { !$0.isPrivate })
        for space in active where spaces.contains(where: { $0.id == space.id }) {
            await ensureLoaded(space: space)
        }
    }

    /// Loads the Space's enabled extensions, once per session. Best-effort: a
    /// bundle that was uninstalled on disk is skipped and logged rather than
    /// failing the switch. A store update that landed while the Space was not
    /// loaded is picked up here, since the library is read now.
    public func ensureLoaded(space: Space) async {
        // Marked before the first await, so a second switch to the Space while
        // this one is still loading doesn't start its workers twice.
        guard loadedSpaces.insert(space.id).inserted else { return }
        let slugs: [String]
        do {
            slugs = space.isPrivate
                ? ((try? installer.installedExtensions()) ?? [])
                    .filter { isAllowedInPrivate(slug: $0.slug) && !refusesPrivate($0) }
                    .map(\.slug)
                : try await enablement.enabledSlugs(spaceID: space.id)
        } catch {
            log.error("could not read enabled extensions: \(String(describing: error))")
            loadedSpaces.remove(space.id)
            return
        }
        guard !slugs.isEmpty else { return }
        let installedBySlug = Dictionary(
            ((try? installer.installedExtensions()) ?? []).map { ($0.slug, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for slug in slugs.sorted() {
            guard let found = installedBySlug[slug] else {
                log.notice("enabled extension \(slug) is no longer installed")
                continue
            }
            // Enabled from Settings while this was still waiting: already on.
            guard !host.loadedExtensions(in: space).contains(where: { $0.slug == slug })
            else { continue }
            let installed = installer.prepareIfNeeded(found)
            do {
                let loaded = try await host.load(installed, in: space)
                // WebKit fails some workers when several extensions start at
                // once. A short gap between background workers is cheap and
                // avoids a dead extension until the next reload.
                if loaded.hasBackgroundContent {
                    try? await Task.sleep(for: .milliseconds(400))
                }
            } catch {
                log.error(
                    "failed to restore \(slug): \(String(describing: error))"
                )
            }
        }
    }
}
