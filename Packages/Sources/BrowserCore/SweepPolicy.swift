import Foundation

/// How long an unpinned tab may sit idle before the sweep closes it.
public enum IdleWindow: Codable, Hashable, Sendable {
    case never
    case after(TimeInterval)

    public static let `default` = IdleWindow.after(12 * 60 * 60)

    public var seconds: TimeInterval? {
        if case .after(let value) = self { return value }
        return nil
    }

    /// The presets offered in Settings, in menu order.
    public static let presets: [IdleWindow] = [
        .never,
        .after(1 * 60 * 60),
        .after(6 * 60 * 60),
        .after(12 * 60 * 60),
        .after(24 * 60 * 60),
    ]

    /// A short label for the picker.
    public var displayName: String {
        switch self {
        case .never: return "Never"
        case .after(let value):
            let hours = Int((value / 3600).rounded())
            return hours == 1 ? "After 1 hour" : "After \(hours) hours"
        }
    }
}

/// Decides which tabs the ephemeral sweep may close.
///
/// Pure, so eligibility is testable without a timer, a clock, or WebKit — feed
/// it a date and it answers (3.6).
public enum SweepPolicy {

    /// Everything the policy needs to judge one tab. Passed in rather than read
    /// off the tab, because "is playing audio" is live engine state that the
    /// model does not carry.
    public struct Candidate: Hashable, Sendable {
        public let tabID: UUID
        public let placement: TabPlacement
        public let lastAccessedAt: Date
        public let isPlayingAudio: Bool
        public let isSelected: Bool

        public init(
            tabID: UUID,
            placement: TabPlacement,
            lastAccessedAt: Date,
            isPlayingAudio: Bool,
            isSelected: Bool
        ) {
            self.tabID = tabID
            self.placement = placement
            self.lastAccessedAt = lastAccessedAt
            self.isPlayingAudio = isPlayingAudio
            self.isSelected = isSelected
        }
    }

    public static func shouldSweep(
        _ candidate: Candidate, now: Date, idleWindow: IdleWindow
    ) -> Bool {
        // "Never" disables the sweep entirely (4.3).
        guard let window = idleWindow.seconds else { return false }

        // Only loose ephemeral tabs are swept — favourites and Pinned tabs are
        // exempt, as are audio-playing tabs (4.3).
        guard candidate.placement.isEphemeral, !candidate.isPlayingAudio else { return false }

        // Closing the tab the user is looking at would be indefensible, however
        // long it has sat there.
        guard !candidate.isSelected else { return false }

        return now.timeIntervalSince(candidate.lastAccessedAt) >= window
    }

    public static func sweepable(
        _ candidates: [Candidate], now: Date, idleWindow: IdleWindow
    ) -> [UUID] {
        candidates
            .filter { shouldSweep($0, now: now, idleWindow: idleWindow) }
            .map(\.tabID)
    }

    /// 4.3: the archive keeps the last 100, newest first.
    public static let archiveLimit = 100

    public static func trimArchive(_ archived: [ArchivedTab]) -> [ArchivedTab] {
        Array(archived.sorted { $0.archivedAt > $1.archivedAt }.prefix(archiveLimit))
    }
}
