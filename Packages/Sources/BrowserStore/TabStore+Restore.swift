import BrowserCore
import Foundation

/// Session restore (M4, BROWSER_SPEC 3.2 and 6.5).
///
/// Two halves that have to agree:
///
/// - **Capture.** `interactionState` is written when a tab is *deactivated*, not
///   on every navigation — the blobs are large and a per-navigation write would
///   be the storage mistake 6.5 names. Eviction already captured state, but only
///   for panes unlucky enough to be evicted; a tab you simply switched away from
///   had nothing stored, so restore was only ever as good as the last eviction.
/// - **Resolution.** Blobs are stored out-of-line and loaded on demand, so a
///   restored pane starts with `interactionState == nil` and the blob is fetched
///   the first time the pane is actually shown. Restore stays lazy: N saved tabs
///   still create zero web views.
@MainActor
extension TabStore {

    enum StateResolution {
        /// The blob is being read; the surface is withheld until it lands, so a
        /// view is never built that would have to discard restored state.
        case pending
        /// Resolved — either seeded into the engine, or there was nothing
        /// stored. Both mean "stop asking".
        case resolved
    }

    // MARK: - Capture

    /// Captures and persists state for every pane of a tab that is going away.
    ///
    /// Panes with no live view are skipped: they have nothing newer to offer
    /// than what is already on disk.
    func captureInteractionState(forTab tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }

        for pane in tab.panes where engine.hasLiveView(paneID: pane.id) {
            guard let state = engine.interactionState(for: pane.id) else { continue }
            persistInteractionState(state, paneID: pane.id)
        }
    }

    /// Captures a single pane that is about to lose its web view — a pane
    /// closed out of a split, where the rest of the tab lives on.
    func captureInteractionState(for paneID: UUID) {
        guard engine.hasLiveView(paneID: paneID),
              let state = engine.interactionState(for: paneID)
        else { return }
        persistInteractionState(state, paneID: paneID)
    }

    /// Marks a brand-new pane resolved. Nothing is stored for it, so a disk read
    /// would only cost a frame of withheld surface.
    func markInteractionStateResolved(_ paneID: UUID) {
        stateResolution[paneID] = .resolved
    }

    /// Captures every live pane, without waiting for the writes. For occlusion,
    /// where the app keeps running.
    public func captureAllInteractionState() {
        let captured = captureLiveState()
        Task { [repository] in await Self.write(captured, to: repository) }
    }

    /// Captures every live pane and *waits* for the writes to land.
    ///
    /// Quit is the one path where fire-and-forget is not good enough: the
    /// process is gone before a detached task runs. `applicationShouldTerminate`
    /// defers termination on this.
    public func flushInteractionState() async {
        await Self.write(captureLiveState(), to: repository)
    }

    /// Only panes with a live view have anything newer than what is on disk.
    private func captureLiveState() -> [(paneID: UUID, state: Data)] {
        var captured: [(paneID: UUID, state: Data)] = []
        // A private pane's blob is never captured — an interaction state carries
        // the URL, the scroll position, and form contents, which is most of what
        // private browsing exists to not write down.
        for tab in tabs where !isPrivate(spaceID: tab.spaceID) {
            for pane in tab.panes where engine.hasLiveView(paneID: pane.id) {
                guard let state = engine.interactionState(for: pane.id) else { continue }
                captured.append((pane.id, state))
            }
        }
        return captured
    }

    private static func write(
        _ captured: [(paneID: UUID, state: Data)], to repository: any TabRepository
    ) async {
        for (paneID, state) in captured {
            do {
                try await repository.saveInteractionState(state, paneID: paneID)
            } catch {
                // A lost blob costs a scroll position, never a tab: the pane
                // still has its URL and reloads.
                Log.store.error(
                    """
                    interaction state save failed for pane \(paneID): \
                    \(String(describing: error))
                    """
                )
            }
        }
    }

    private func persistInteractionState(_ state: Data, paneID: UUID) {
        guard !isPrivate(paneID: paneID) else { return }
        Task { [repository] in
            await Self.write([(paneID, state)], to: repository)
        }
    }

    // MARK: - Resolution

    /// Reads the stored blob for each of a tab's panes and hands it to the
    /// engine, so the view is built from state rather than reloaded.
    ///
    /// Marks panes resolved even when nothing was stored — otherwise a pane with
    /// no state would be asked for on every render and never draw.
    func resolveInteractionState(forTab tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }

        for pane in tab.panes {
            guard stateResolution[pane.id] == nil else { continue }
            // Nothing was ever stored for a private pane, so a disk read could
            // only come back nil after withholding the surface for a frame.
            guard !isPrivate(spaceID: tab.spaceID) else {
                markInteractionStateResolved(pane.id)
                continue
            }
            guard !engine.hasLiveView(paneID: pane.id) else {
                stateResolution[pane.id] = .resolved
                continue
            }
            stateResolution[pane.id] = .pending
            resolve(paneID: pane.id)
        }
    }

    private func resolve(paneID: UUID) {
        Task { [repository, engine] in
            let state: Data?
            do {
                state = try await repository.loadInteractionState(paneID: paneID)
            } catch {
                Log.store.error(
                    """
                    interaction state load failed for pane \(paneID): \
                    \(String(describing: error))
                    """
                )
                state = nil
            }

            if let state { engine.seedInteractionState(state, for: paneID) }
            // Mutating this is what re-renders the content view and lets the
            // surface through.
            stateResolution[paneID] = .resolved
        }
    }

    /// True while a pane's stored state is still being read.
    func isAwaitingInteractionState(_ paneID: UUID) -> Bool {
        stateResolution[paneID] == .pending
    }

    /// Forgets resolution bookkeeping for panes that no longer exist, so the
    /// dictionary cannot grow for the life of the process.
    func forgetStateResolution(forPanes paneIDs: [UUID]) {
        for paneID in paneIDs { stateResolution[paneID] = nil }
    }
}
