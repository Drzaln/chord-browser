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
    public let version: String?
    /// True when the bundle came from the Chrome Web Store, so update checks
    /// know where to ask.
    public let fromStore: Bool
    public let resourceURL: URL
    /// `.unsigned` when nothing is recorded — the honest default for a bundle
    /// installed before signing checks existed, or a plain ZIP.
    public let signatureStatus: ExtensionSignatureStatus

    public init(
        slug: String,
        identifier: String? = nil,
        version: String? = nil,
        fromStore: Bool = false,
        resourceURL: URL,
        signatureStatus: ExtensionSignatureStatus = .unsigned
    ) {
        self.slug = slug
        self.identifier = identifier ?? slug
        self.version = version
        self.fromStore = fromStore
        self.resourceURL = resourceURL
        self.signatureStatus = signatureStatus
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
        let zip = try ExtensionArchive.zipPayload(from: data)
        // Pinned signer keys: none yet — no extension store exists. The
        // verifier's set is empty, so the outcome is `.verified` (valid
        // signature, unvouched signer) or a warning state.
        let signatureStatus = ExtensionSignatureVerifier.verify(data, pinnedKeys: [])

        let slug = Self.slug(for: URL(fileURLWithPath: sourceName))
        let fm = FileManager.default
        try fm.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        let destination = resourceURL(forSlug: slug)
        // The raw ZIP lands first: even if preparation fails, the library has
        // the exact signed bytes for a later retry or a manual inspection.
        try zip.write(to: destination, options: .atomic)

        let staging = extensionsDirectory.appending(
            path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var identifier = ExtensionSignatureVerifier.extensionIdentifier(in: data)
        var version: String?
        var preparedURL: URL?

        let extracted = staging.appending(path: "prepared", directoryHint: .isDirectory)
        do {
            try ExtensionBundle.extract(zip, to: extracted)
            let manifest = try ExtensionBundle.manifest(at: extracted)
            version = manifest["version"] as? String
            if identifier == nil {
                identifier = ExtensionBundle.fallbackIdentifier(
                    manifest: manifest,
                    source: sourceURL ?? URL(fileURLWithPath: sourceName)
                )
            }
            try ExtensionShims.prepare(extracted, fresh: true)
            let target = self.preparedURL(forSlug: slug)
            try ExtensionFiles.replace(extracted, at: target)
            preparedURL = target
        } catch {
            // Keep the library usable for the UI and let WebKit produce the
            // real load error. Remove any previous prepared tree so a broken
            // reinstall cannot keep serving the old bundle.
            try? fm.removeItem(at: self.preparedURL(forSlug: slug))
            Log.extensions.error(
                "could not prepare \(slug): \(String(describing: error))"
            )
        }

        try signatureStatus.rawValue.write(
            to: verificationURL(forSlug: slug), atomically: true, encoding: .utf8
        )
        try (identifier ?? slug).write(
            to: identityURL(forSlug: slug), atomically: true, encoding: .utf8
        )
        if fromStore {
            try "1".write(to: storeURL(forSlug: slug), atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(at: storeURL(forSlug: slug))
        }

        Log.extensions.notice(
            "installed extension \(slug) as \(identifier ?? slug) (signature: \(signatureStatus.rawValue))"
        )
        return InstalledExtension(
            slug: slug,
            identifier: identifier,
            version: version,
            fromStore: fromStore,
            resourceURL: preparedURL ?? destination,
            signatureStatus: signatureStatus
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
                return InstalledExtension(
                    slug: slug,
                    identifier: identifier,
                    version: version,
                    fromStore: FileManager.default.fileExists(
                        atPath: storeURL(forSlug: slug).path
                    ),
                    resourceURL: hasPrepared ? prepared : entry,
                    signatureStatus: verificationStatus(forSlug: slug)
                )
            }
            .sorted { $0.slug < $1.slug }
    }

    /// Bring a bundle installed before the prepared layout up to date: unpack
    /// the stored ZIP, inject the shim, derive a Chrome id, and write the
    /// identity sidecar. Best-effort: a bundle that cannot be prepared is
    /// returned unchanged, so it still loads the old way.
    public func prepareIfNeeded(_ installed: InstalledExtension) -> InstalledExtension {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: installed.resourceURL.path, isDirectory: &isDirectory
        ), isDirectory.boolValue {
            return installed
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
                version: manifest["version"] as? String,
                fromStore: installed.fromStore,
                resourceURL: preparedURL(forSlug: installed.slug),
                signatureStatus: installed.signatureStatus
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
