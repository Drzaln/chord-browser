import BrowserCore
import Foundation

/// The ephemeral-tab sweep (4.3).
@MainActor
extension TabStore {

    /// 4.3: a background sweep runs every five minutes.
    static let sweepInterval: Duration = .seconds(5 * 60)

    /// Starts the periodic sweep. Idempotent.
    ///
    /// This is a task loop, not a timer driving a view: the sweep mutates the
    /// model and the model triggers a diff. Nothing polls `body` (6.4).
    public func startSweep() {
        guard sweepTask == nil else { return }

        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: TabStore.sweepInterval)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.sweepNow()
            }
        }
    }

    public func stopSweep() {
        sweepTask?.cancel()
        sweepTask = nil
    }

    /// Closes every eligible tab and archives it. Exposed so tests and the
    /// smoke checklist do not have to wait five minutes.
    public func sweepNow() async {
        // Nothing is swept while the window is hidden — the sweep is paused
        // along with everything else that would cost CPU when occluded (6.3).
        guard !isOccluded else { return }

        let now = clock.now
        let candidates = tabs.map { tab in
            SweepPolicy.Candidate(
                tabID: tab.id,
                placement: tab.placement,
                lastAccessedAt: tab.lastAccessedAt,
                isPlayingAudio: runtimes[tab.focusedPaneID]?.isPlayingAudio ?? false,
                isSelected: tab.id == selectedTabID
            )
        }

        let doomed = Set(SweepPolicy.sweepable(candidates, now: now, idleWindow: idleWindow))
        guard !doomed.isEmpty else { return }

        let closing = tabs.filter { doomed.contains($0.id) }

        // Archive before closing. The sweep never hard-deletes (4.3) — if the
        // archive write fails, the tabs stay open rather than vanishing.
        do {
            try await archiveRepository?.archive(
                closing.map { ArchivedTab(tab: $0, archivedAt: now) }
            )
        } catch {
            Log.store.error("archive failed, leaving tabs open: \(String(describing: error))")
            return
        }

        for tab in closing {
            for pane in tab.panes {
                engine.evict(paneID: pane.id)
                runtimes[pane.id] = nil
            }
        }
        tabs.removeAll { doomed.contains($0.id) }

        Log.store.notice("swept \(closing.count, privacy: .public) idle tab(s)")

        if visibleTabs.isEmpty { newTab() }
        scheduleSave()
    }

    /// Reopens an archived tab in its original Space when that Space still
    /// exists, and in the active one when it does not.
    public func restoreArchived(_ archived: ArchivedTab) {
        let spaceID = spaces.contains { $0.id == archived.spaceID }
            ? archived.spaceID
            : activeSpace?.id

        guard let spaceID else { return }

        if spaceID != activeSpaceID { selectSpace(spaceID) }

        let order = (tabs.filter { $0.spaceID == spaceID }.map(\.placement.order).max() ?? -1) + 1
        var tab = Tab(
            url: archived.url,
            spaceID: spaceID,
            placement: .ephemeral(order: order),
            now: clock.now
        )
        tab.updatePane(tab.focusedPaneID) { pane in
            pane.title = archived.title
            pane.faviconData = archived.faviconData
        }

        tabs.append(tab)
        selectedTabID = tab.id
        scheduleSave()
    }
}
