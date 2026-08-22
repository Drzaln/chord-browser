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

/// Live implementation against the GitHub REST API (`/releases/latest`).
/// GitHub requires a User-Agent header, so one is always sent.
public struct GitHubReleaseChecking: ReleaseChecking {
    public let repository: String // "owner/repo"
    public let userAgent: String
    private let session: URLSession

    public init(repository: String, userAgent: String, session: URLSession = .shared) {
        self.repository = repository
        self.userAgent = userAgent
        self.session = session
    }

    public func latestRelease() async throws -> GitHubRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw ReleaseCheckingError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw ReleaseCheckingError.badResponse
        }
        switch http.statusCode {
        case 200: break
        case 404: return nil // no releases published yet
        default: throw ReleaseCheckingError.httpStatus(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw ReleaseCheckingError.decoding(String(describing: error))
        }
    }
}