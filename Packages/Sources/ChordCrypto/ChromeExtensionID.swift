import CryptoKit
import Foundation

/// Chrome-compatible extension identifiers.
///
/// A Chrome extension id is not a name anybody chooses: it is the first 16
/// bytes of the SHA-256 of the extension's public key, written as 32 letters
/// from `a` to `p`. Chrome Web Store bundles carry that key in their CRX
/// header; an unpacked folder has no key, so Chrome derives one from the
/// folder's real path instead.
///
/// Chord uses the same spelling because native-messaging hosts, extension
/// origins (`chrome-extension://<id>/`) and store update checks all speak it.
/// The installer keeps a separate, human-readable `slug` for the on-disk
/// library; the id is what WebKit and Chrome-facing protocols see.
public enum ChromeExtensionID {
    /// 32 letters from `a` to `p`, one for each half-byte.
    public static func letters(_ bytes: Data) -> String {
        String(bytes.prefix(16).flatMap { [$0 >> 4, $0 & 0x0f] }.map {
            Character(UnicodeScalar(UInt8(ascii: "a") + $0))
        })
    }

    /// The id Chrome gives the public key in a CRX header.
    public static func fromPublicKey(_ spki: Data) -> String {
        letters(Data(SHA256.hash(data: spki)))
    }

    /// The id Chrome gives an unpacked extension, from the folder's real path.
    /// `resolvingSymlinksInPath()` is important: the same folder reached by
    /// two paths must keep one id.
    public static func fromPath(_ url: URL) -> String {
        let real = url.resolvingSymlinksInPath().standardizedFileURL.path
        return letters(Data(SHA256.hash(data: Data(real.utf8))))
    }

    /// A manifest's `key` is a base64-encoded SubjectPublicKeyInfo blob.
    public static func fromManifestKey(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64, options: []) else { return nil }
        return fromPublicKey(data)
    }

    /// A bare id, or one found in a store link. Only the id shape; callers
    /// decide whether the source is trustworthy.
    public static func parse(_ text: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: "(?<![a-p])([a-p]{32})(?![a-p])")
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text.lowercased(), range: range),
              let found = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[found]).lowercased()
    }

    public static func isValid(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { ("a"..."p").contains($0) }
    }
}
