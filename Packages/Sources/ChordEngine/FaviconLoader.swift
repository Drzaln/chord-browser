import AppKit
import Foundation

/// Fetches and downsamples favicons, cached on disk by origin.
///
/// Full-size images are never retained: everything is downsampled to display
/// size before it is stored or handed back (6.5).
actor FaviconLoader {
    static let displaySize = CGSize(width: 32, height: 32)

    private let cacheDirectory: URL
    private let session: URLSession
    private var inFlight: [String: Task<Data?, Never>] = [:]

    init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true
        )

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: config)
    }

    /// Suspended while the window is occluded (6.3).
    var isPaused = false

    func setPaused(_ paused: Bool) { isPaused = paused }

    func favicon(for pageURL: URL, declaredHref: URL?) async -> Data? {
        guard !isPaused, let origin = Self.origin(of: pageURL) else { return nil }

        if let cached = cachedData(origin: origin) { return cached }
        if let existing = inFlight[origin] { return await existing.value }

        let candidates = [declaredHref, URL(string: "/favicon.ico", relativeTo: origin.asURL)]
            .compactMap(\.self)

        let task = Task<Data?, Never> { [session] in
            for candidate in candidates {
                guard let (data, response) = try? await session.data(from: candidate),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let downsampled = Self.downsample(data)
                else { continue }
                return downsampled
            }
            return nil
        }
        inFlight[origin] = task

        let result = await task.value
        inFlight[origin] = nil
        if let result { store(result, origin: origin) }
        return result
    }

    // MARK: - Disk cache

    private func cacheFile(origin: String) -> URL {
        cacheDirectory.appending(path: "\(Self.filename(for: origin)).png")
    }

    private func cachedData(origin: String) -> Data? {
        try? Data(contentsOf: cacheFile(origin: origin))
    }

    private func store(_ data: Data, origin: String) {
        do {
            try data.write(to: cacheFile(origin: origin), options: .atomic)
        } catch {
            Log.favicon.debug("favicon cache write failed: \(error.localizedDescription)")
        }
    }

    private static func filename(for origin: String) -> String {
        origin.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
    }

    // MARK: - Image handling

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host() else { return nil }
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    private static func downsample(_ data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }

        let target = NSImage(size: displaySize)
        target.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: displaySize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        target.unlockFocus()

        guard let tiff = target.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

private extension String {
    var asURL: URL? { URL(string: self) }
}
