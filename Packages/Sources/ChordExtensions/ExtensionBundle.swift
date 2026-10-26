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
