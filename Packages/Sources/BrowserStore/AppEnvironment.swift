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
    /// Present when the extensions flag is on (M7, 7.4). The app uses it to list,
    /// install, enable, and disable extensions. `nil` when extensions are off.
    public let extensions: ExtensionsService?
    /// Retained strongly here: the engine holds the provider `weak` so a live
    /// browser must keep the host alive somewhere, and this environment is the
    /// object with the app's lifetime. `nil` when the extensions flag is off,
    /// in which case no host exists and the engine attaches no controller (M7).
    public let extensionHost: (any ExtensionHost)?

    public init(
        store: TabStore,
        downloads: DownloadsStore,
        extensionHost: (any ExtensionHost)? = nil,
        extensions: ExtensionsService? = nil
    ) {
        self.store = store
        self.downloads = downloads
        self.extensionHost = extensionHost
        self.extensions = extensions
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

        let store = TabStore(
            engine: engine,
            repository: repository,
            spaceRepository: repository,
            historyRepository: history,
            archiveRepository: history,
            clock: SystemClock()
        )

        // Wire the tab/window model both ways (7.3b) when extensions are on. The
        // store is the model the adapters read; the engine, forwarded as an
        // existential, is the provider that vends a pane's live web view. Neither
        // line names a WebKit type, so the Store stays WebKit-free.
        var extensionsService: ExtensionsService?
        if let host = extensionHost as? WebKitExtensionHost {
            host.tabModel = store
            host.paneWebViewProvider = engine
            store.extensionHost = host

            // The library, the host, and the enablement store, coordinated (7.4).
            let service = ExtensionsService(
                installer: ExtensionInstaller(
                    extensionsDirectory: support.appending(path: "Extensions")
                ),
                host: host,
                enablement: SQLiteExtensionEnablementRepository(database: database)
            )
            extensionsService = service
            // Re-load enabled extensions once the Spaces they belong to have been
            // restored. `restore()` invokes this at its end.
            store.afterRestore = { [weak store] in
                guard let store else { return }
                await service.restoreEnabled(spaces: store.spaces)
            }
        }

        return AppEnvironment(
            store: store,
            downloads: DownloadsStore(coordinator: engine.downloads),
            extensionHost: extensionHost,
            extensions: extensionsService
        )
    }
}
