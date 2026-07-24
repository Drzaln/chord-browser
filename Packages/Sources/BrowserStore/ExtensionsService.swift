import BrowserCore
import BrowserExtensions
import Foundation
import os

public enum ExtensionsServiceError: Error, CustomStringConvertible {
    case notInstalled(String)
    public var description: String {
        switch self {
        case .notInstalled(let slug): "no installed extension with slug \(slug)"
        }
    }
}

/// Coordinates the three parts of the extension subsystem the app drives
/// (M7, 7.4): the on-disk library (`ExtensionInstaller`), the per-Space host
/// (`ExtensionHost`), and the enablement store (`ExtensionEnablementRepository`).
///
/// WebKit-free at its surface — it deals in slugs, `Space`s, `InstalledExtension`
/// and `LoadedExtension` — so it lives in `BrowserStore` and needs no WebKit
/// import. Enable is load + persist; disable is unload + persist; and on launch
/// `restoreEnabled` re-loads whatever was on before the last quit.
@MainActor
public final class ExtensionsService {
    private let installer: ExtensionInstaller
    private let host: any ExtensionHost
    private let enablement: any ExtensionEnablementRepository
    private let log = Logger(subsystem: "com.rizal.browser", category: "extensions")

    public init(
        installer: ExtensionInstaller,
        host: any ExtensionHost,
        enablement: any ExtensionEnablementRepository
    ) {
        self.installer = installer
        self.host = host
        self.enablement = enablement
    }

    public func installedExtensions() throws -> [InstalledExtension] {
        try installer.installedExtensions()
    }

    public func enabledExtensions(in space: Space) -> [LoadedExtension] {
        host.loadedExtensions(in: space)
    }

    @discardableResult
    public func install(from url: URL) throws -> InstalledExtension {
        try installer.install(from: url)
    }

    /// Loads the extension into the Space and records it as enabled. Persists
    /// only after the load succeeds, so a bundle that fails to load is not left
    /// marked on.
    public func enable(slug: String, in space: Space) async throws {
        guard let installed = try installer.installedExtensions().first(where: { $0.slug == slug })
        else { throw ExtensionsServiceError.notInstalled(slug) }
        try await host.load(installed, in: space)
        try await enablement.setEnabled(true, slug: slug, spaceID: space.id)
    }

    public func disable(slug: String, in space: Space) async throws {
        try host.unload(slug: slug, in: space)
        try await enablement.setEnabled(false, slug: slug, spaceID: space.id)
    }

    /// Re-loads every enabled extension after the store has restored its Spaces.
    /// Best-effort: a bundle that was uninstalled on disk, or a Space that no
    /// longer exists, is skipped and logged rather than failing the launch.
    public func restoreEnabled(spaces: [Space]) async {
        let records: [ExtensionEnablementRecord]
        do {
            records = try await enablement.allEnabled()
        } catch {
            log.error("could not read enabled extensions: \(String(describing: error))")
            return
        }
        let installedBySlug = Dictionary(
            ((try? installer.installedExtensions()) ?? []).map { ($0.slug, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let spacesByID = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for record in records {
            guard let space = spacesByID[record.spaceID] else { continue }
            guard let installed = installedBySlug[record.slug] else {
                log.notice("enabled extension \(record.slug, privacy: .public) is no longer installed")
                continue
            }
            do {
                try await host.load(installed, in: space)
            } catch {
                log.error(
                    "failed to restore \(record.slug, privacy: .public): \(String(describing: error))"
                )
            }
        }
    }
}
