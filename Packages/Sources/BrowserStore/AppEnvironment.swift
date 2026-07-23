import BrowserCore
import BrowserEngine
import BrowserPersistence
import Foundation

/// Constructed once at launch and passed down. No singletons, no service
/// locator, and services never travel through the SwiftUI environment (3.6).
@MainActor
public struct AppEnvironment {
    public let store: TabStore
    public let downloads: DownloadsStore

    public init(store: TabStore, downloads: DownloadsStore) {
        self.store = store
        self.downloads = downloads
    }

    /// The real, on-disk configuration.
    public static func live(applicationName: String = "Browser") throws -> AppEnvironment {
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
            downloads: DownloadsStore(coordinator: engine.downloads)
        )
    }
}
