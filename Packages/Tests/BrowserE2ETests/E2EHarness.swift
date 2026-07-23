import BrowserCore
import BrowserEngine
import BrowserPersistence
import BrowserStore
import BrowserTestSupport
import Foundation

/// Wires the whole stack together the way the app does — real `WebKitEngine`,
/// real SQLite on disk, real `TabStore` — against a local HTTP server.
///
/// Nothing here is faked except the clock, which is injected so the sweep can
/// be tested without waiting twelve hours.
@MainActor
final class E2EHarness {
    let store: TabStore
    let server: TestHTTPServer
    let directory: URL
    private(set) var clock: MutableClock
    /// Downloads land here rather than in the real ~/Downloads.
    private(set) var downloads: DownloadsStore

    var downloadsDirectory: URL { directory.appending(path: "Downloads") }

    private init(
        store: TabStore,
        server: TestHTTPServer,
        directory: URL,
        clock: MutableClock,
        downloads: DownloadsStore
    ) {
        self.store = store
        self.server = server
        self.directory = directory
        self.clock = clock
        self.downloads = downloads
    }

    static func make(
        routes: [TestHTTPServer.Route],
        directory: URL? = nil,
        clock: MutableClock = MutableClock()
    ) async throws -> E2EHarness {
        let server = try TestHTTPServer(routes: routes)
        try await server.start()

        let directory = directory ?? URL.temporaryDirectory
            .appending(path: "browser-e2e-\(UUID().uuidString)")

        let built = try makeStore(directory: directory, clock: clock)
        return E2EHarness(
            store: built.store,
            server: server,
            directory: directory,
            clock: clock,
            downloads: built.downloads
        )
    }

    /// Builds a second store over the *same* directory — this is what "quit and
    /// relaunch" means for these tests.
    func relaunch() throws -> TabStore {
        try Self.makeStore(directory: directory, clock: clock).store
    }

    private static func makeStore(
        directory: URL, clock: MutableClock
    ) throws -> (store: TabStore, downloads: DownloadsStore) {
        let database = try BrowserDatabase.open(
            at: directory.appending(path: "browser.sqlite")
        )
        let repository = SQLiteTabRepository(database: database)
        let history = SQLiteHistoryRepository(database: database)

        let engine = WebKitEngine(
            configuration: EngineConfiguration(
                faviconCacheDirectory: directory.appending(path: "Favicons")
            ),
            downloads: DownloadCoordinator(
                directory: directory.appending(path: "Downloads")
            )
        )

        let store = TabStore(
            engine: engine,
            repository: repository,
            spaceRepository: repository,
            historyRepository: history,
            archiveRepository: history,
            clock: clock
        )
        return (store, DownloadsStore(coordinator: engine.downloads))
    }

    func tearDown() async {
        store.stopSweep()
        await server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Waiting

    /// Polls until `condition` holds. Real page loads are asynchronous and
    /// event-driven; a fixed sleep would be both slower and flakier.
    @discardableResult
    func wait(
        timeout: Duration = .seconds(10),
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    /// Opens a tab on `url` and waits until the page has actually loaded.
    func openAndLoad(_ url: URL, timeout: Duration = .seconds(10)) async -> Bool {
        store.newTab(url: url)
        guard let tab = store.selectedTab else { return false }

        // Requesting the surface is what creates the web view — the same path
        // the UI takes when a tab becomes visible.
        _ = store.surface(for: tab)

        return await wait(timeout: timeout) {
            let runtime = self.store.runtime(for: tab.focusedPaneID)
            return !runtime.isLoading && runtime.currentURL != nil
        }
    }
}

/// A clock the tests can move forward, so the sweep is testable without waiting
/// out a real idle window.
final class MutableClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = now
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current += interval
    }
}
