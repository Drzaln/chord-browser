import ChordCrypto
import Foundation

/// Extracts a verified extension ZIP into a directory WebKit can read and
/// Chord can rewrite. `WKWebExtension` reads a ZIP directly, but the shim is
/// injected into the worker, content scripts and pages, so a prepared copy
/// must be a real tree.
///
/// The extraction uses macOS's own `ditto`, not a hand-written ZIP parser:
/// one less place to get deflate, central directories and zip-slip wrong.
/// Symlinks are refused whole, as in Search, because a later rewrite would
/// otherwise follow one out of the package.
public enum ExtensionBundle {
    public enum Failure: Error, LocalizedError, CustomStringConvertible {
        case badArchive(String)
        case manifestMissing
        case symlink(String)

        public var errorDescription: String? { description }

        public var description: String {
            switch self {
            case .badArchive(let why): "could not unpack the extension: \(why)"
            case .manifestMissing: "the extension has no manifest.json"
            case .symlink(let path): "the extension contains a symbolic link: \(path)"
            }
        }
    }

    /// Unpack `zip` into `folder`, replacing whatever was there. The caller
    /// must give a staging path on the same volume as the final location.
    public static func extract(_ zip: Data, to folder: URL) throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(
            path: "chord-extract-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        defer { try? fm.removeItem(at: scratch) }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let archive = scratch.appending(path: "bundle.zip")
        try zip.write(to: archive)
        let out = scratch.appending(path: "out", directoryHint: .isDirectory)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, out.path]
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw Failure.badArchive("ditto exited \(ditto.terminationStatus)")
        }
        guard fm.fileExists(atPath: out.appending(path: "manifest.json").path) else {
            throw Failure.manifestMissing
        }
        try rejectSymlinks(in: out)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(
            at: folder.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fm.moveItem(at: out, to: folder)
    }

    /// Reads the manifest from an extracted extension.
    public static func manifest(at folder: URL) throws -> [String: Any] {
        let url = folder.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.manifestMissing }
        return manifest
    }

    public static func version(at folder: URL) -> String? {
        (try? manifest(at: folder))?["version"] as? String
    }

    /// The name a person should see. Many store bundles carry
    /// `"__MSG_extName__"` and keep the real name in `_locales`; leaving the
    /// placeholder in the manager is worse than showing the slug.
    /// Whether the manifest refuses private browsing (`"incognito":
    /// "not_allowed"`), which Chrome honours whatever the user allowed. WebKit
    /// doesn't read that key, so Chord does.
    public static func refusesPrivate(at folder: URL) -> Bool {
        ((try? manifest(at: folder))?["incognito"] as? String) == "not_allowed"
    }

    public static func displayName(at folder: URL) -> String? {
        guard let manifest = try? manifest(at: folder) else { return nil }
        guard let raw = manifest["name"] as? String else { return nil }
        let localized = localize(raw, manifest: manifest, folder: folder)
        return localized.isEmpty ? nil : localized
    }

    /// Resolves `__MSG_key__` placeholders from the extension's default locale
    /// (then English, then the first locale present). A key that cannot be
    /// found is left as written, as Chrome does for an unknown key.
    private static func localize(
        _ value: String, manifest: [String: Any], folder: URL
    ) -> String {
        guard value.contains("__MSG_") else { return value }
        let locales = folder.appending(path: "_locales", directoryHint: .isDirectory)
        let fm = FileManager.default
        let available = (try? fm.contentsOfDirectory(atPath: locales.path)) ?? []
        let preferred = [manifest["default_locale"] as? String, "en", "en_US", "en_GB"]
            .compactMap { $0 }
        let chosen = preferred.first { available.contains($0) } ?? available.first
        guard let chosen,
              let data = try? Data(contentsOf: locales.appending(path: "\(chosen)/messages.json")),
              let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return value }
        var result = value
        let pattern = #"__MSG_([A-Za-z0-9_@]+?)__"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let whole = Range(match.range(at: 0), in: result),
                  let keyRange = Range(match.range(at: 1), in: value)
            else { continue }
            let key = String(value[keyRange])
            guard let entry = messages[key] as? [String: Any],
                  let message = entry["message"] as? String
            else { continue }
            result.replaceSubrange(whole, with: message)
        }
        return result
    }

    /// Chrome gives an unpacked folder an id from its path; a manifest `key`
    /// is stronger when present, because it travels with the package.
    public static func fallbackIdentifier(manifest: [String: Any], source: URL) -> String {
        if let key = manifest["key"] as? String,
           let id = ChromeExtensionID.fromManifestKey(key) {
            return id
        }
        return ChromeExtensionID.fromPath(source)
    }

    private static func rejectSymlinks(in folder: URL) throws {
        let fm = FileManager.default
        let walker = fm.enumerator(
            at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]
        )
        while let item = walker?.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw Failure.symlink(item.lastPathComponent)
            }
        }
    }
}
