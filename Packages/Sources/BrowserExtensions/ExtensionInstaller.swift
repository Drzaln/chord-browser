import Foundation

/// An extension bundle sitting on disk, ready for `WKWebExtension` to read.
///
/// `resourceURL` is the normalised ZIP; 7.3 hands it to
/// `WKWebExtension.extension(resourceBaseURL:)`. `slug` is the install
/// directory name and, for now, the handle the UI uses to enable/remove it —
/// 7.3+ replaces it with WebKit's own `uniqueIdentifier` once a context loads.
public struct InstalledExtension: Sendable, Equatable, Identifiable {
    public var id: String { slug }
    public let slug: String
    public let resourceURL: URL

    public init(slug: String, resourceURL: URL) {
        self.slug = slug
        self.resourceURL = resourceURL
    }
}

/// Installs `.crx`/`.xpi` bundles into the on-disk extension library and lists
/// what is there (BROWSER_SPEC 4.7, phase 7.2).
///
/// **Why a ZIP on disk, not an unpacked directory.** The plan said "unpack into
/// a directory", but `WKWebExtension`'s `resourceBaseURL` initializer reads a
/// ZIP archive directly (SDK header: "a directory with a `manifest.json` file
/// **or a ZIP archive** containing a `manifest.json` file"). Storing the ZIP as
/// WebKit already accepts it means no ZIP extractor of our own — none of the
/// zip-slip, deflate, or central-directory parsing a hand-rolled unpacker would
/// carry, for a bundle WebKit re-reads anyway. So the only transform is
/// stripping the CRX signature header; `.xpi` is copied through. See ADR 011.
///
/// **MV3 enforcement is deferred to load (7.3),** where `WKWebExtension`
/// actually parses the manifest and reports `manifestVersion`. Nothing here
/// reads inside the ZIP.
public struct ExtensionInstaller: Sendable {
    /// `~/Library/Application Support/Browser/Extensions/` in the live app.
    public let extensionsDirectory: URL

    public init(extensionsDirectory: URL) {
        self.extensionsDirectory = extensionsDirectory
    }

    /// Normalises a `.crx`/`.xpi` at `sourceURL` into the library and returns
    /// its descriptor. Reinstalling the same filename overwrites in place.
    @discardableResult
    public func install(from sourceURL: URL) throws -> InstalledExtension {
        let data = try Data(contentsOf: sourceURL)
        let zip = try ExtensionArchive.zipPayload(from: data)

        let slug = Self.slug(for: sourceURL)
        let fm = FileManager.default
        try fm.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)

        let destination = resourceURL(forSlug: slug)
        // Overwrite a prior install of the same name rather than erroring, so
        // reinstalling a rebuilt extension just works.
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try zip.write(to: destination, options: .atomic)

        Log.extensions.notice("installed extension \(slug)")
        return InstalledExtension(slug: slug, resourceURL: destination)
    }

    /// Every installed extension, sorted by slug for a stable list.
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
            .map { InstalledExtension(slug: $0.deletingPathExtension().lastPathComponent, resourceURL: $0) }
            .sorted { $0.slug < $1.slug }
    }

    public func remove(slug: String) throws {
        let fm = FileManager.default
        let url = resourceURL(forSlug: slug)
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
        Log.extensions.notice("removed extension \(slug)")
    }

    private func resourceURL(forSlug slug: String) -> URL {
        extensionsDirectory.appending(path: "\(slug).zip")
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
