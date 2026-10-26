import ChordCrypto
import Foundation

/// Chrome Web Store downloads.
///
/// The store hands a browser a CRX from the same public update endpoint every
/// Chromium browser uses. Chord asks for the CRX3 form, verifies its signature
/// through `ExtensionSignatureVerifier`, then installs the ZIP exactly like a
/// file the person picked. Nothing is unpacked before the signature check.
public enum Crx {
    public enum Refused: LocalizedError {
        case notAnID, download(Int), empty, notCrx, unsignedOrWrong

        public var errorDescription: String? {
            switch self {
            case .notAnID: "That isn't a Chrome Web Store link or extension id"
            case .download(let code): "The Chrome Web Store answered \(code)"
            case .empty: "The Chrome Web Store has nothing for that id"
            case .notCrx: "What came back isn't a Chrome extension"
            case .unsignedOrWrong: "The extension's signature doesn't hold up"
            }
        }
    }

    public static let chromeVersion = ExtensionShims.chromeVersion

    /// A bare id, or one found in a store link.
    public static func id(in text: String) -> String? {
        ChromeExtensionID.parse(text)
    }

    /// The extension a store page is about: the id in its `/detail/` path and
    /// nowhere else. Only on the store itself, over https, with no credentials
    /// before the host. The page may ask; the address is what counts.
    public static func storeID(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil
        else { return nil }
        let host = url.host()?.lowercased() ?? ""
        let pattern: String
        switch host {
        case "chromewebstore.google.com":
            pattern = #"^/detail/(?:[^/]+/)?([a-p]{32})(?:/.*)?$"#
        case "chrome.google.com":
            pattern = #"/webstore/detail/(?:[^/]+/)?([a-p]{32})(?:/.*)?$"#
        default:
            return nil
        }
        let path = url.path
        guard let match = try? NSRegularExpression(pattern: pattern)
            .firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let found = Range(match.range(at: 1), in: path)
        else { return nil }
        return String(path[found])
    }

    public static func downloadURL(for id: String) -> URL {
        var parts = URLComponents(
            string: "https://clients2.google.com/service/update2/crx"
        )!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc"),
        ]
        return parts.url!
    }

    public static func fetch(_ id: String) async throws -> Data {
        guard ChromeExtensionID.isValid(id) else { throw Refused.notAnID }
        var request = URLRequest(url: downloadURL(for: id))
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw Refused.download(http.statusCode)
        }
        guard !data.isEmpty else { throw Refused.empty }
        guard data.starts(with: Data("Cr24".utf8)) else { throw Refused.notCrx }
        return data
    }
}
