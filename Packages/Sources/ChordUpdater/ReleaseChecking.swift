import Foundation

/// Answers "what is the latest release?", so the updater is testable without
/// touching the network.
public protocol ReleaseChecking: Sendable {
    /// The latest published release, or nil when the repository has none.
    func latestRelease() async throws -> GitHubRelease?
}

public enum ReleaseCheckingError: Error, LocalizedError, Sendable {
    case invalidURL
    case badResponse
    case httpStatus(Int)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The repository address is invalid."
        case .badResponse: "GitHub returned a response the updater could not read."
        case .httpStatus(let code): "GitHub responded with HTTP \(code)."
        case .decoding(let detail): "Could not read the release data: \(detail)"
        }
    }
}

/// Live implementation that reads the latest release **without the GitHub API**.
///
/// The REST endpoint (`api.github.com/.../releases/latest`) is rate-limited to
/// 60 requests/hour per IP for unauthenticated callers — easy to exhaust, and
/// the update check paid for it with a 403. The public *web* URLs have no such
/// limit, and they already encode what the updater needs:
///
/// - `https://github.com/<repo>/releases/latest` 302-redirects to the actual
///   tag page, so the version is read from the `Location` header.
/// - `https://github.com/<repo>/releases/latest/download/<asset>` redirects to
///   that version's asset, so the zip URL needs no version number at all.
public struct GitHubReleaseChecking: ReleaseChecking {
    public let repository: String // "owner/repo"
    public let userAgent: String
    public let assetName: String
    private let session: URLSession

    public init(
        repository: String,
        userAgent: String,
        assetName: String = "Chord.zip",
        session: URLSession = .shared
    ) {
        self.repository = repository
        self.userAgent = userAgent
        self.assetName = assetName
        self.session = session
    }

    public func latestRelease() async throws -> GitHubRelease? {
        guard let url = URL(string: "https://github.com/\(repository)/releases/latest") else {
            throw ReleaseCheckingError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        // Don't follow the redirect: the 302's Location header carries the tag.
        let noRedirect = URLSession(
            configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil
        )
        defer { noRedirect.finishTasksAndInvalidate() }

        let (_, response) = try await noRedirect.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReleaseCheckingError.badResponse
        }
        switch http.statusCode {
        case 302:
            guard let location = http.value(forHTTPHeaderField: "Location"),
                  let tag = Self.parseTag(from: location) else {
                throw ReleaseCheckingError.badResponse
            }
            return makeRelease(tag: tag)
        case 404:
            return nil // no releases published yet
        default:
            throw ReleaseCheckingError.httpStatus(http.statusCode)
        }
    }

    /// The tag from a `releases/latest` redirect, e.g.
    /// `https://github.com/Drzaln/chord-browser/releases/tag/v1.4.4` → `v1.4.4`.
    /// Everything after `/releases/tag/` is kept, so tags containing `/` work.
    static func parseTag(from location: String) -> String? {
        if let range = location.range(of: "/releases/tag/") {
            let tag = String(location[range.upperBound...])
            return tag.isEmpty ? nil : tag
        }
        return URL(string: location)?.lastPathComponent
    }

    private func makeRelease(tag: String) -> GitHubRelease {
        let base = "https://github.com/\(repository)"
        return GitHubRelease(
            tagName: tag,
            name: tag,
            htmlURL: URL(string: "\(base)/releases/tag/\(tag)")!,
            isPrerelease: false,
            publishedAt: nil,
            assets: [
                GitHubRelease.Asset(
                    name: assetName,
                    downloadURL: URL(string: "\(base)/releases/latest/download/\(assetName)")!,
                    sizeBytes: nil,
                    contentType: "application/zip"
                )
            ]
        )
    }
}

/// Tells URLSession to hand back the redirect response instead of following it.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}