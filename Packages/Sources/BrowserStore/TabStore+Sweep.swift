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
        // Foldered tabs are exempt — a folder is a place to keep tabs, so the
        // sweep never touches them (non-spec: user-requested).
        // Private tabs are never swept — not merely never archived. The archive
        // write records URL and title, and `isSelectedByAnyWindow` only protects
        // the *selected* tab, so a background private tab would otherwise land on
        // disk. A private session is bounded by its window, not by an idle clock.
        let candidates = tabs
            .filter { $0.folderID == nil && !isPrivate(spaceID: $0.spaceID) }
            .map { tab in
            SweepPolicy.Candidate(
                tabID: tab.id,
                placement: tab.placement,
                lastAccessedAt: tab.lastAccessedAt,
                isPlayingAudio: runtimes[tab.focusedPaneID]?.isPlayingAudio ?? false,
                // Selected in *any* window. A tab on screen in a second window
                // is not idle, and sweeping it would close a page the user is
                // looking at.
                isSelected: isSelectedByAnyWindow(tab.id)
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

        Log.store.notice("swept \(closing.count) idle tab(s)")

        // Every window that just lost its whole list needs a tab again.
        for window in windows where visibleTabs(in: window).isEmpty {
            newTab(in: window)
        }
        // The sweep is not driven by any window, so no window is excluded.
        reconcileWindows()
        scheduleSave()
    }

    /// Reopens an archived tab in its original Space when that Space still
    /// exists, and in the active one when it does not.
    public func restoreArchived(_ archived: ArchivedTab, in window: WindowState) {
        let spaceID = spaces.contains { $0.id == archived.spaceID }
            ? archived.spaceID
            : activeSpace(in: window)?.id

        guard let spaceID else { return }

        if spaceID != window.activeSpaceID { selectSpace(spaceID, in: window) }

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
        window.selectedTabID = tab.id
        scheduleSave()
    }
}
