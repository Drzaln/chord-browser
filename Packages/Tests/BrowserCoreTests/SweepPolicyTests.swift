import BrowserCore
import Foundation
import Testing

@Suite("Ephemeral sweep eligibility")
struct SweepPolicyTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func candidate(
        placement: TabPlacement = .ephemeral(order: 0),
        idleFor seconds: TimeInterval,
        isPlayingAudio: Bool = false,
        isSelected: Bool = false
    ) -> SweepPolicy.Candidate {
        SweepPolicy.Candidate(
            tabID: UUID(),
            placement: placement,
            lastAccessedAt: now.addingTimeInterval(-seconds),
            isPlayingAudio: isPlayingAudio,
            isSelected: isSelected
        )
    }

    private let twelveHours: TimeInterval = 12 * 60 * 60

    @Test("An idle ephemeral tab past the window is swept")
    func idleTabIsSwept() {
        let tab = candidate(idleFor: twelveHours + 1)
        #expect(SweepPolicy.shouldSweep(tab, now: now, idleWindow: .default))
    }

    @Test("A tab inside the window is left alone")
    func freshTabSurvives() {
        let tab = candidate(idleFor: twelveHours - 60)
        #expect(!SweepPolicy.shouldSweep(tab, now: now, idleWindow: .default))
    }

    @Test("Exactly at the window counts as idle")
    func boundaryIsInclusive() {
        let tab = candidate(idleFor: twelveHours)
        #expect(SweepPolicy.shouldSweep(tab, now: now, idleWindow: .default))
    }

    @Test("Pinned tabs are exempt however long they sit")
    func pinnedIsExempt() {
        let tab = candidate(placement: .pinned(order: 0), idleFor: twelveHours * 100)
        #expect(!SweepPolicy.shouldSweep(tab, now: now, idleWindow: .default))
    }

    @Test("A tab playing audio is exempt")
    func audioIsExempt() {
        let tab = candidate(idleFor: twelveHours * 10, isPlayingAudio: true)
        #expect(!SweepPolicy.shouldSweep(tab, now: now, idleWindow: .default))
    }

    @Test("The tab you are looking at is never swept")
    func selectedIsExempt() {
        let tab = candidate(idleFor: twelveHours * 10, isSelected: true)
        #expect(!SweepPolicy.shouldSweep(tab, now: now, idleWindow: .default))
    }

    @Test("An idle window of never disables the sweep entirely")
    func neverDisablesSweep() {
        let tab = candidate(idleFor: twelveHours * 1000)
        #expect(!SweepPolicy.shouldSweep(tab, now: now, idleWindow: .never))
    }

    @Test("A custom window is honoured")
    func customWindow() {
        let tab = candidate(idleFor: 90 * 60)
        #expect(SweepPolicy.shouldSweep(tab, now: now, idleWindow: .after(60 * 60)))
        #expect(!SweepPolicy.shouldSweep(tab, now: now, idleWindow: .after(2 * 60 * 60)))
    }

    @Test("sweepable returns only the eligible ids")
    func sweepableFilters() {
        let doomed = candidate(idleFor: twelveHours * 2)
        let pinned = candidate(placement: .pinned(order: 0), idleFor: twelveHours * 2)
        let fresh = candidate(idleFor: 60)

        let result = SweepPolicy.sweepable(
            [doomed, pinned, fresh], now: now, idleWindow: .default
        )
        #expect(result == [doomed.tabID])
    }

    @Test("The archive keeps the newest 100 and drops the rest")
    func archiveTrims() {
        let archived = (0..<150).map { index in
            ArchivedTab(
                url: URL(string: "https://example.com/\(index)")!,
                title: "Tab \(index)",
                spaceID: UUID(),
                archivedAt: now.addingTimeInterval(TimeInterval(index))
            )
        }

        let trimmed = SweepPolicy.trimArchive(archived)

        #expect(trimmed.count == SweepPolicy.archiveLimit)
        #expect(trimmed.first?.title == "Tab 149")  // newest kept
        #expect(!trimmed.contains { $0.title == "Tab 0" })  // oldest dropped
    }

    @Test("An archived tab does not carry the interactionState blob")
    func archiveDropsBlobs() {
        var tab = Tab(
            url: URL(string: "https://example.com")!,
            spaceID: UUID(),
            placement: .ephemeral(order: 0),
            now: now
        )
        tab.updatePane(tab.focusedPaneID) { $0.interactionState = Data(repeating: 0xAB, count: 999) }

        let archived = ArchivedTab(tab: tab, archivedAt: now)

        // The archive is for finding a tab again, not for restoring its scroll
        // position — the blobs are large and not worth keeping (6.5).
        #expect(archived.url == tab.focusedPane.url)
        #expect(archived.spaceID == tab.spaceID)
    }
}
