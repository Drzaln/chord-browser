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

    public private(set) var createdPanes: [UUID] = []
    public private(set) var evictedPanes: [UUID] = []
    public private(set) var loadedURLs: [(UUID, URL)] = []
    public private(set) var backCount = 0
    public private(set) var forwardCount = 0
    public private(set) var reloadCount = 0
    public private(set) var stopCount = 0

    public var snapshots: [UUID: PaneSnapshot] = [:]

    public init() {}

    public func surface(for pane: Pane) -> AnyWebSurface {
        if !createdPanes.contains(pane.id) { createdPanes.append(pane.id) }
        return .empty(id: pane.id)
    }

    public func load(_ url: URL, in paneID: UUID) { loadedURLs.append((paneID, url)) }
    public func goBack(in paneID: UUID) { backCount += 1 }
    public func goForward(in paneID: UUID) { forwardCount += 1 }
    public func reload(paneID: UUID) { reloadCount += 1 }
    public func stopLoading(paneID: UUID) { stopCount += 1 }

    public func snapshot(for paneID: UUID) -> PaneSnapshot? { snapshots[paneID] }

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

    /// Drives the delegate as WebKit would.
    public func emit(_ snapshot: PaneSnapshot, for paneID: UUID) {
        snapshots[paneID] = snapshot
        delegate?.paneDidUpdate(paneID, snapshot: snapshot)
    }

    public func emitFavicon(_ data: Data?, for paneID: UUID) {
        delegate?.paneDidLoadFavicon(paneID, data: data)
    }

    public func emitNewTabRequest(url: URL) {
        delegate?.paneRequestedNewTab(url: url)
    }
}

public actor FakeTabRepository: TabRepository {
    public private(set) var stored: [Tab]
    public private(set) var saveCount = 0
    public var loadError: (any Error)?

    private var interactionStates: [UUID: Data] = [:]

    public init(stored: [Tab] = []) {
        self.stored = stored
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

    public func setLoadError(_ error: (any Error)?) { loadError = error }
}
