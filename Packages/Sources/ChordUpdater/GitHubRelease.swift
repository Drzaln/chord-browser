import Foundation

/// The `/releases/latest` payload. Decoded leniently: only `tag_name` is
/// required; everything else falls back so the updater can show what it has
/// even if GitHub's payload shape shifts.
public struct GitHubRelease: Sendable, Hashable, Identifiable {
    public let tagName: String
    public let name: String
    public let htmlURL: URL
    public let isPrerelease: Bool
    public let publishedAt: Date?
    public let assets: [Asset]

    public var id: String { tagName }

    public var version: Version? { Version(raw: tagName) }

    /// The first `.zip` asset, which is the installable bundle (`Chord.zip`).
    public var zipAsset: Asset? {
        assets.first { $0.name.lowercased().hasSuffix(".zip") }
    }

    public struct Asset: Sendable, Hashable {
        public let name: String
        public let downloadURL: URL
        public let sizeBytes: Int64?
        public let contentType: String?
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case isPrerelease = "prerelease"
        case publishedAt = "published_at"
        case assets
    }

    enum AssetCodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case contentType = "content_type"
    }
}

extension GitHubRelease: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? tagName
        htmlURL = try container.decodeIfPresent(URL.self, forKey: .htmlURL)
            ?? URL(string: "https://github.com")!
        isPrerelease = try container.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }
}

extension GitHubRelease.Asset: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: GitHubRelease.AssetCodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        downloadURL = try container.decode(URL.self, forKey: .browserDownloadURL)
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .size)
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
    }
}