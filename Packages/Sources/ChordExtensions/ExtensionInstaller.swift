import ChordCore
import ChordCrypto
import Foundation

/// An extension bundle sitting on disk, ready for `WKWebExtension` to read.
///
/// `resourceURL` is the prepared directory when the bundle unpacked cleanly,
/// or the stored ZIP when it did not. `slug` is the human-readable on-disk
/// library name; `identifier` is Chrome's id — 32 letters from `a` to `p` —
/// used for `chrome-extension://<id>/`, native messaging and update checks.
/// `signatureStatus` is the verdict stamped at install (persisted next to the
/// bundle) so the UI can warn about untrusted extensions without re-reading a
/// header that was stripped on install.
public struct InstalledExtension: Sendable, Equatable, Identifiable {
    /// The library's stable name, used by the UI and enablement records.
    public var id: String { slug }
    public let slug: String
    public let identifier: String
    /// The manifest's `name`, for people: a store install's slug is its
    /// 32-letter Chrome id, which is not something to show in a list.
    public let displayName: String?
    public let version: String?
    /// True when the bundle came from the Chrome Web Store, so update checks
    /// know where to ask.
    public let fromStore: Bool
    public let resourceURL: URL
    /// `.unsigned` when nothing is recorded — the honest default for a bundle
    /// installed before signing checks existed, or a plain ZIP.
    public let signatureStatus: ExtensionSignatureStatus
    /// What the user agreed it may do when they installed it (or last let an
    /// update grow it), as `ExtensionConsent.grants` lists it. Nil for an
    /// install nobody was asked about (from before install consent), which
    /// still asks for site access when enabled.
    public let consentedGrants: [String]?

    public init(
        slug: String,
        identifier: String? = nil,
        displayName: String? = nil,
        version: String? = nil,
        fromStore: Bool = false,
        resourceURL: URL,
        signatureStatus: ExtensionSignatureStatus = .unsigned,
        consentedGrants: [String]? = nil
    ) {
        self.slug = slug
        self.identifier = identifier ?? slug
        self.displayName = displayName
        self.version = version
        self.fromStore = fromStore
        self.resourceURL = resourceURL
        self.signatureStatus = signatureStatus
        self.consentedGrants = consentedGrants
    }
}

/// Installs `.crx`/`.xpi` bundles into the on-disk extension library and lists
/// what is there (BROWSER_SPEC 4.7, phase 7.2).
///
/// The raw ZIP is kept for provenance, and — when it unpacks — a prepared
/// directory sits beside it. The prepared copy is where Chord's shim is
/// injected; the ZIP stays exactly as the signer shipped it, so the signature
/// verdict remains meaningful. `WKWebExtension` can read either form.
///
/// A bundle that cannot be unpacked still installs as before, and will be
/// rejected by WebKit when loaded. That keeps a corrupt file diagnosable
/// instead of silently disappearing.
///
/// **MV3 enforcement is deferred to load (7.3),** where `WKWebExtension`
/// actually parses the manifest and reports `manifestVersion`.
public struct ExtensionInstaller: Sendable {
    /// `~/Library/Application Support/Chord/Extensions/` in the live app.
    public let extensionsDirectory: URL

    public init(extensionsDirectory: URL) {
        self.extensionsDirectory = extensionsDirectory
    }

    /// Normalises a `.crx`/`.xpi` at `sourceURL` into the library and returns
    /// its descriptor. Reinstalling the same filename overwrites in place.
    @discardableResult
    public func install(from sourceURL: URL) throws -> InstalledExtension {
        try install(
            data: Data(contentsOf: sourceURL),
            sourceName: sourceURL.lastPathComponent,
            sourceURL: sourceURL
        )
    }

    /// Install bytes that did not come from a file picker — a store download.
    /// `sourceName` supplies the library slug when the CRX carries no id.
    @discardableResult
    public func install(
        data: Data, sourceName: String, sourceURL: URL? = nil,
        fromStore: Bool = false
    ) throws -> InstalledExtension {
        try commit(
            stage(data: data, sourceName: sourceName, sourceURL: sourceURL, fromStore: fromStore),
            consented: nil
        )
    }

    /// A bundle verified, unpacked and prepared, but not yet in the library:
    /// what the user is asked about before installing (or updating) it. Either
    /// `commit` it or `discard` it; until then nothing of it is in the
    /// library.
    public struct Staged: Sendable {
        public let slug: String
        public let identifier: String
        public let displayName: String?
        public let version: String?
        public let fromStore: Bool
        public let signatureStatus: ExtensionSignatureStatus
        /// The prepared folder in staging, or the staged ZIP when the bundle
        /// didn't unpack. What `WKWebExtension` reads to say what it asks for.
        public let resourceURL: URL
        let folder: URL
        let zip: URL
        let prepared: URL?
    }

    /// Reads, verifies and prepares a bundle in a staging folder inside the
    /// library directory (one volume, so `commit` is a move).
    public func stage(
        data: Data, sourceName: String, sourceURL: URL? = nil, fromStore: Bool = false
    ) throws -> Staged {
        let zipData = try ExtensionArchive.zipPayload(from: data)
        // Pinned signer keys: none yet — no extension store exists. The
        // verifier's set is empty, so the outcome is `.verified` (valid
        // signature, unvouched signer) or a warning state.
        let signatureStatus = ExtensionSignatureVerifier.verify(data, pinnedKeys: [])

        let slug = Self.slug(for: URL(fileURLWithPath: sourceName))
        let fm = FileManager.default
        try fm.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        let folder = extensionsDirectory.appending(
            path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appending(path: "bundle.zip")
        do {
            try zipData.write(to: zip, options: .atomic)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }

        var identifier = ExtensionSignatureVerifier.extensionIdentifier(in: data)
        var displayName: String?
        var version: String?
        var prepared: URL?

        let extracted = folder.appending(path: "prepared", directoryHint: .isDirectory)
        do {
            try ExtensionBundle.extract(zipData, to: extracted)
            let manifest = try ExtensionBundle.manifest(at: extracted)
            displayName = ExtensionBundle.displayName(at: extracted)
            version = manifest["version"] as? String
            if identifier == nil {
                identifier = ExtensionBundle.fallbackIdentifier(
                    manifest: manifest,
                    source: sourceURL ?? URL(fileURLWithPath: sourceName)
                )
            }
            try ExtensionShims.prepare(extracted, fresh: true)
            prepared = extracted
        } catch {
            // Keep the library usable for the UI and let WebKit produce the
            // real load error.
            Log.extensions.error(
                "could not prepare \(slug): \(String(describing: error))"
            )
        }
        return Staged(
            slug: slug, identifier: identifier ?? slug, displayName: displayName,
            version: version, fromStore: fromStore, signatureStatus: signatureStatus,
            resourceURL: prepared ?? zip, folder: folder, zip: zip, prepared: prepared
        )
    }

    /// Leaves nothing of a staged bundle behind: the user said no.
    public func discard(_ staged: Staged) {
        try? FileManager.default.removeItem(at: staged.folder)
    }

    /// Moves a staged bundle into the library, over any earlier copy of the
    /// slug. `consented` is what the user agreed it may do (`ExtensionConsent.
    /// grants`), recorded so an update that asks for more is asked about
    /// again; nil when nobody was asked.
    @discardableResult
    public func commit(_ staged: Staged, consented: [String]?) throws -> InstalledExtension {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: staged.folder) }
        let slug = staged.slug
        let destination = resourceURL(forSlug: slug)
        // The raw ZIP lands first: even if preparation failed, the library has
        // the exact signed bytes for a later retry or a manual inspection.
        try Data(contentsOf: staged.zip).write(to: destination, options: .atomic)

        var preparedURL: URL?
        if let prepared = staged.prepared {
            let target = self.preparedURL(forSlug: slug)
            try ExtensionFiles.replace(prepared, at: target)
            preparedURL = target
        } else {
            // A broken reinstall must not keep serving the old bundle.
            try? fm.removeItem(at: self.preparedURL(forSlug: slug))
        }

        try staged.signatureStatus.rawValue.write(
            to: verificationURL(forSlug: slug), atomically: true, encoding: .utf8
        )
        try staged.identifier.write(
            to: identityURL(forSlug: slug), atomically: true, encoding: .utf8
        )
        if staged.fromStore {
            try "1".write(to: storeURL(forSlug: slug), atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(at: storeURL(forSlug: slug))
        }
        if let consented, let data = try? JSONSerialization.data(withJSONObject: consented.sorted()) {
            try data.write(to: consentURL(forSlug: slug), options: .atomic)
        } else {
            try? fm.removeItem(at: consentURL(forSlug: slug))
        }

        Log.extensions.notice(
            "installed extension \(slug) as \(staged.identifier) (signature: \(staged.signatureStatus.rawValue))"
        )
        return InstalledExtension(
            slug: slug,
            identifier: staged.identifier,
            displayName: staged.displayName,
            version: staged.version,
            fromStore: staged.fromStore,
            resourceURL: preparedURL ?? destination,
            signatureStatus: staged.signatureStatus,
            consentedGrants: consented
        )
    }

    /// Every installed extension, sorted by slug for a stable list, with the
    /// signature verdict read back from each one's sidecar. An install from
    /// before this layout has no identity sidecar; its id is derived from the
    /// prepared manifest when one exists, and otherwise stays its slug.
    public func installedExtensions() throws -> [InstalledExtension] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: extensionsDirectory.path) else { return [] }
        let entries = try fm.contentsOfDirectory(
            at: extensionsDirectory,
            includingPropertiesForKeys: nil
        )
        return
            entries
            .filter { $0.pathExtension == "zip" }
            .map { entry in
                let slug = entry.deletingPathExtension().lastPathComponent
                let prepared = preparedURL(forSlug: slug)
                let hasPrepared = fm.fileExists(atPath: prepared.path)
                let identifier = identity(forSlug: slug)
                    ?? (hasPrepared
                        ? (try? ExtensionBundle.manifest(at: prepared)).map {
                            ExtensionBundle.fallbackIdentifier(manifest: $0, source: entry)
                        }
                        : nil)
                    ?? slug
                let version = hasPrepared ? ExtensionBundle.version(at: prepared) : nil
                let displayName = hasPrepared
                    ? ExtensionBundle.displayName(at: prepared)
                    : nil
                return InstalledExtension(
                    slug: slug,
                    identifier: identifier,
                    displayName: displayName,
                    version: version,
                    fromStore: FileManager.default.fileExists(
                        atPath: storeURL(forSlug: slug).path
                    ),
                    resourceURL: hasPrepared ? prepared : entry,
                    signatureStatus: verificationStatus(forSlug: slug),
                    consentedGrants: consent(forSlug: slug)
                )
            }
            .sorted { $0.slug < $1.slug }
    }

    /// Bring a bundle installed before the prepared layout up to date: unpack
    /// the stored ZIP, inject the shim, derive a Chrome id, and write the
    /// identity sidecar. A prepared tree stamped with an older shim is
    /// re-prepared too, so a shim fix actually reaches existing installs.
    /// Best-effort: a bundle that cannot be prepared is returned unchanged, so
    /// it still loads the old way.
    public func prepareIfNeeded(_ installed: InstalledExtension) -> InstalledExtension {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: installed.resourceURL.path, isDirectory: &isDirectory
        ), isDirectory.boolValue {
            let stamp = try? String(
                contentsOf: installed.resourceURL.appending(path: ExtensionShims.stamp),
                encoding: .utf8
            )
            if ExtensionShims.isCurrent(stamp: stamp) { return installed }
        }
        let zipURL = resourceURL(forSlug: installed.slug)
        guard let data = try? Data(contentsOf: zipURL) else { return installed }
        let fm = FileManager.default
        let staging = extensionsDirectory.appending(
            path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try ExtensionBundle.extract(data, to: staging.appending(path: "prepared"))
            let prepared = staging.appending(path: "prepared", directoryHint: .isDirectory)
            let manifest = try ExtensionBundle.manifest(at: prepared)
            let identifier = identity(forSlug: installed.slug)
                ?? ExtensionBundle.fallbackIdentifier(manifest: manifest, source: zipURL)
            try ExtensionShims.prepare(prepared, fresh: true)
            try ExtensionFiles.replace(prepared, at: preparedURL(forSlug: installed.slug))
            try identifier.write(
                to: identityURL(forSlug: installed.slug), atomically: true, encoding: .utf8
            )
            return InstalledExtension(
                slug: installed.slug,
                identifier: identifier,
                displayName: ExtensionBundle.displayName(at: prepared),
                version: manifest["version"] as? String,
                fromStore: installed.fromStore,
                resourceURL: preparedURL(forSlug: installed.slug),
                signatureStatus: installed.signatureStatus,
                consentedGrants: installed.consentedGrants
            )
        } catch {
            Log.extensions.error(
                "could not prepare existing \(installed.slug): \(String(describing: error))"
            )
            return installed
        }
    }

    public func remove(slug: String) throws {
        let fm = FileManager.default
        let url = resourceURL(forSlug: slug)
        let hadBundle = fm.fileExists(atPath: url.path)
            || fm.fileExists(atPath: preparedURL(forSlug: slug).path)
        guard hadBundle else { return }
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: preparedURL(forSlug: slug))
        try? fm.removeItem(at: verificationURL(forSlug: slug))
        try? fm.removeItem(at: identityURL(forSlug: slug))
        try? fm.removeItem(at: storeURL(forSlug: slug))
        try? fm.removeItem(at: consentURL(forSlug: slug))
        Log.extensions.notice("removed extension \(slug)")
    }

    private func resourceURL(forSlug slug: String) -> URL {
        extensionsDirectory.appending(path: "\(slug).zip")
    }

    /// The unpacked, shim-prepared copy. Kept beside the raw ZIP.
    private func preparedURL(forSlug slug: String) -> URL {
        extensionsDirectory.appending(path: "\(slug).prepared", directoryHint: .isDirectory)
    }

    /// The persisted signature verdict for an installed bundle. Missing means
    /// the bundle predates signature checks (or is a plain ZIP) — `.unsigned`.
    private func verificationURL(forSlug slug: String) -> URL {
        extensionsDirectory.appending(path: "\(slug).verification")
    }

    /// Chrome's id for the bundle, written at install.
    private func identityURL(forSlug slug: String) -> URL {
        extensionsDirectory.appending(path: "\(slug).identity")
    }

    private func storeURL(forSlug slug: String) -> URL {
        extensionsDirectory.appending(path: "\(slug).store")
    }

    /// What the user agreed it may do, as a JSON array of grants.
    private func consentURL(forSlug slug: String) -> URL {
        extensionsDirectory.appending(path: "\(slug).consent.json")
    }

    private func consent(forSlug slug: String) -> [String]? {
        guard let data = try? Data(contentsOf: consentURL(forSlug: slug)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String]
    }

    private func verificationStatus(forSlug slug: String) -> ExtensionSignatureStatus {
        let url = verificationURL(forSlug: slug)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return .unsigned }
        return ExtensionSignatureStatus(rawValue: raw) ?? .unsigned
    }

    private func identity(forSlug slug: String) -> String? {
        guard let raw = try? String(contentsOf: identityURL(forSlug: slug), encoding: .utf8)
        else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChromeExtensionID.isValid(id) ? id : nil
    }

    /// A file-system-safe folder name from the source filename's stem. Keeps
    /// letters, digits, dash, and underscore; collapses everything else to a
    /// dash so a hostile name cannot escape the directory or collide with the
    /// `.zip` suffix logic.
    static func slug(for sourceURL: URL) -> String {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let allowed = CharacterSet(charactersIn: "-_").union(.alphanumerics)
        let cleaned = String(
            stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        )
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "extension" : trimmed
    }
}
