import BrowserCore
import BrowserEngine
import Foundation

public struct FixedClock: Clock {
    public var now: Date
    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.now = now
    }
}

/// Records what the store asked for, so sweep, eviction, and restore logic can
/// be tested with zero WebKit involvement (3.6).
@MainActor
public final class FakeWebEngine: WebEngine {
    public weak var delegate: (any WebEngineDelegate)?
    public weak var extensionControllerProvider: (any ExtensionControllerProviding)?

    public private(set) var createdPanes: [UUID] = []
    public private(set) var evictedPanes: [UUID] = []
    public private(set) var loadedURLs: [(UUID, URL)] = []
    public private(set) var backCount = 0
    public private(set) var forwardCount = 0
    public private(set) var reloadCount = 0
    public private(set) var stopCount = 0

    public var snapshots: [UUID: PaneSnapshot] = [:]

    public init() {}

    /// Records which Space each view was built against, so tests can assert
    /// that a pane never gets a view from the wrong data store.
    public private(set) var spaceForPane: [UUID: UUID] = [:]
    public private(set) var removedDataForSpaces: [UUID] = []
    public var removeDataError: (any Error)?

    public func surface(for pane: Pane, in space: Space) -> AnyWebSurface {
        if !createdPanes.contains(pane.id) { createdPanes.append(pane.id) }
        spaceForPane[pane.id] = space.id
        return .empty(id: pane.id)
    }

    public func removeData(for space: Space) async throws {
        if let removeDataError { throw removeDataError }
        removedDataForSpaces.append(space.id)
    }

    public private(set) var clearedData: [(types: BrowsingDataType, spaceIDs: [UUID])] = []
    public func clearWebsiteData(_ types: BrowsingDataType, forSpaces spaces: [Space]) async {
        clearedData.append((types, spaces.map(\.id)))
    }

    public func load(_ url: URL, in paneID: UUID) { loadedURLs.append((paneID, url)) }
    public func goBack(in paneID: UUID) { backCount += 1 }
    public func goForward(in paneID: UUID) { forwardCount += 1 }
    public func reload(paneID: UUID) { reloadCount += 1 }
    public func stopLoading(paneID: UUID) { stopCount += 1 }

    public private(set) var mutedPanes: Set<UUID> = []
    public func setMuted(_ muted: Bool, paneID: UUID) {
        if muted { mutedPanes.insert(paneID) } else { mutedPanes.remove(paneID) }
    }

    public private(set) var sleepTimers: [UUID: Date] = [:]
    public private(set) var cancelledSleepTimers: [UUID] = []
    public func setSleepTimer(after seconds: TimeInterval, paneID: UUID) {
        sleepTimers[paneID] = Date().addingTimeInterval(seconds)
    }
    public func cancelSleepTimer(paneID: UUID) {
        if sleepTimers[paneID] != nil { cancelledSleepTimers.append(paneID) }
        sleepTimers.removeValue(forKey: paneID)
    }

    public private(set) var stoppedScreenShares: [UUID] = []
    public func stopScreenSharing(paneID: UUID) {
        stoppedScreenShares.append(paneID)
    }

    public private(set) var customUserAgent: String?
    public private(set) var customUserAgentSetCount = 0
    public private(set) var userAgentOverrides: [UserAgentOverride] = []

    public func setUserAgent(_ global: UserAgentPreference, overrides: [UserAgentOverride]) {
        customUserAgent = global.resolvedUserAgent
        userAgentOverrides = overrides
        customUserAgentSetCount += 1
    }

    /// What a URL would actually be sent with, so a test can assert the policy
    /// without a web view.
    public func resolvedUserAgent(for url: URL?) -> String? {
        UserAgentRules.resolve(
            url: url, overrides: userAgentOverrides,
            global: customUserAgent.map { .custom($0) } ?? .default
        )
    }

    /// What the last `fillLogin` was asked to do, so a test can assert the store
    /// passed the right credential to the right pane without a real page.
    public struct RecordedFill: Equatable, Sendable {
        public let paneID: UUID
        public let expectedOrigin: String
        public let username: String
        public let password: String
    }
    public private(set) var fills: [RecordedFill] = []
    /// What `fillLogin` should report. Defaults to a full success.
    public var fillOutcome: LoginFillOutcome = .filled(username: true, password: true)

    public func fillLogin(
        paneID: UUID,
        expectedOrigin: String,
        usernameFieldID: String?,
        username: String,
        passwordFieldID: String?,
        password: String
    ) async -> LoginFillOutcome {
        fills.append(
            RecordedFill(
                paneID: paneID, expectedOrigin: expectedOrigin,
                username: username, password: password
            )
        )
        return fillOutcome
    }

    public func snapshot(for paneID: UUID) -> PaneSnapshot? { snapshots[paneID] }

    public private(set) var notificationClicks: [(jsID: String, paneID: UUID)] = []
    public func dispatchNotificationClick(jsID: String, toPane paneID: UUID) {
        notificationClicks.append((jsID, paneID))
    }

    public private(set) var printedPanes: [UUID] = []
    public func printPane(paneID: UUID) { printedPanes.append(paneID) }

    /// Find-in-page. `findMatches` is the text the fake pretends the page
    /// contains, so a test can drive both the hit and the miss.
    public var findMatches: Set<String> = []
    /// How long a given query takes to answer. Without this the fake replies
    /// synchronously and queries always complete in the order they were made,
    /// which makes an out-of-order result impossible to stage — and a test for
    /// one passes whether or not the code guards against it.
    public var findDelays: [String: Duration] = [:]
    public private(set) var findQueries: [(paneID: UUID, text: String, backwards: Bool)] = []
    public private(set) var clearedFindPanes: [UUID] = []

    public func find(_ text: String, in paneID: UUID, backwards: Bool) async -> Bool {
        findQueries.append((paneID, text, backwards))
        if let delay = findDelays[text] {
            // Deliberately not cancellation-aware: the point is to let a
            // superseded query finish and try to report, so the store's own
            // guard is what has to stop it.
            try? await Task.sleep(for: delay)
        }
        return findMatches.contains(text)
    }

    public func clearFind(in paneID: UUID) { clearedFindPanes.append(paneID) }

    @discardableResult
    public func evict(paneID: UUID) -> Data? {
        evictedPanes.append(paneID)
        createdPanes.removeAll { $0 == paneID }
        return nil
    }

    public func evictAll() {
        createdPanes.forEach { evictedPanes.append($0) }
        createdPanes.removeAll()
    }

    public func liveViewCount() -> Int { createdPanes.count }

    /// State the fake will report for a live pane, as WebKit would.
    public var interactionStates: [UUID: Data] = [:]
    /// What the store seeded before a view was built — the assertion that
    /// restore actually reached the engine.
    public private(set) var seededStates: [UUID: Data] = [:]

    public func interactionState(for paneID: UUID) -> Data? { interactionStates[paneID] }

    public func hasLiveView(paneID: UUID) -> Bool { createdPanes.contains(paneID) }

    public func seedInteractionState(_ data: Data, for paneID: UUID) {
        guard !createdPanes.contains(paneID) else { return }
        seededStates[paneID] = data
        interactionStates[paneID] = data
    }

    /// Drives the delegate as WebKit would.
    public func emit(_ snapshot: PaneSnapshot, for paneID: UUID) {
        snapshots[paneID] = snapshot
        delegate?.paneDidUpdate(paneID, snapshot: snapshot)
    }

    public func emitFavicon(_ data: Data?, for paneID: UUID) {
        delegate?.paneDidLoadFavicon(paneID, data: data)
    }

    /// - Parameter paneID: the pane the page called `window.open()` from. Nil
    ///   models a request whose opener has already been evicted.
    public func emitNewTabRequest(url: URL, fromPane paneID: UUID? = nil) {
        delegate?.paneRequestedNewTab(url: url, fromPane: paneID)
    }
}

public actor FakeTabRepository: TabRepository, SpaceRepository {
    public private(set) var stored: [Tab]
    public private(set) var storedSpaces: [Space]
    public private(set) var saveCount = 0
    public private(set) var spaceSaveCount = 0
    public var loadError: (any Error)?

    private var interactionStates: [UUID: Data] = [:]

    public init(stored: [Tab] = [], spaces: [Space] = []) {
        self.stored = stored
        self.storedSpaces = spaces
    }

    public func loadSpaces() async throws -> [Space] { storedSpaces }

    public func saveSpaces(_ spaces: [Space]) async throws {
        storedSpaces = spaces
        spaceSaveCount += 1
    }

    public func loadAll() async throws -> [Tab] {
        if let loadError { throw loadError }
        return stored
    }

    public func save(_ tabs: [Tab]) async throws {
        stored = tabs
        saveCount += 1
    }

    public func loadInteractionState(paneID: UUID) async throws -> Data? {
        interactionStates[paneID]
    }

    public func saveInteractionState(_ data: Data?, paneID: UUID) async throws {
        interactionStates[paneID] = data
    }

    public private(set) var prunedKeepingCounts: [Int] = []

    public func pruneInteractionStates(keeping paneIDs: Set<UUID>) async throws {
        prunedKeepingCounts.append(paneIDs.count)
        interactionStates = interactionStates.filter { paneIDs.contains($0.key) }
    }

    /// Lets a test see exactly what restore would read back.
    public func storedInteractionStateCount() -> Int { interactionStates.count }

    public func setLoadError(_ error: (any Error)?) { loadError = error }
}

/// In-memory window-layout persistence for tests (v9).
public actor FakeWindowLayoutRepository: WindowLayoutRepository {
    public private(set) var stored: [WindowLayout]
    public private(set) var saveCount = 0

    public init(stored: [WindowLayout] = []) {
        self.stored = stored
    }

    public func loadWindowLayouts() async throws -> [WindowLayout] { stored }

    public func saveWindowLayouts(_ layouts: [WindowLayout]) async throws {
        stored = layouts
        saveCount += 1
    }
}
