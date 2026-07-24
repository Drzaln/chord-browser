import BrowserCore
import BrowserEngine
import BrowserExtensions
import BrowserPersistence
import Foundation

/// Constructed once at launch and passed down. No singletons, no service
/// locator, and services never travel through the SwiftUI environment (3.6).
@MainActor
public struct AppEnvironment {
    public let store: TabStore
    public let downloads: DownloadsStore
    /// Retained strongly here: the engine holds the provider `weak` so a live
    /// browser must keep the host alive somewhere, and this environment is the
    /// object with the app's lifetime. `nil` when the extensions flag is off,
    /// in which case no host exists and the engine attaches no controller (M7).
    public let extensionHost: (any ExtensionHost)?

    public init(
        store: TabStore,
        downloads: DownloadsStore,
        extensionHost: (any ExtensionHost)? = nil
    ) {
        self.store = store
        self.downloads = downloads
        self.extensionHost = extensionHost
    }

    /// The real, on-disk configuration.
    public static func live(
        applicationName: String = "Browser",
        flags: FeatureFlags = .default
    ) throws -> AppEnvironment {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: applicationName)

        let database = try BrowserDatabase.open(at: support.appending(path: "browser.sqlite"))

        let engine = WebKitEngine(
            configuration: EngineConfiguration(
                faviconCacheDirectory: support.appending(path: "Favicons"),
                applicationName: applicationName
            )
        )

        // In-progress M7 sits behind a flag (7.4): with it off the host is not
        // built and the engine's provider stays nil, so the browser is exactly
        // what it was before M7 — no controllers, no extra processes.
        let extensionHost: (any ExtensionHost)?
        if flags.extensionsEnabled {
            let host = WebKitExtensionHost()
            engine.extensionControllerProvider = host
            extensionHost = host
        } else {
            extensionHost = nil
        }

        let repository = SQLiteTabRepository(database: database)
        let history = SQLiteHistoryRepository(database: database)

        return AppEnvironment(
            store: TabStore(
                engine: engine,
                repository: repository,
                spaceRepository: repository,
                historyRepository: history,
                archiveRepository: history,
                clock: SystemClock()
            ),
            downloads: DownloadsStore(coordinator: engine.downloads),
            extensionHost: extensionHost
        )
    }
}
