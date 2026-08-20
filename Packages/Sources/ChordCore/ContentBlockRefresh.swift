import Foundation

/// The weekly-refresh schedule for content blocking (§4.8, milestone C3), kept
/// as pure date arithmetic in Core so "is a refresh due?" is testable without a
/// network, a clock, or WebKit.
public enum ContentBlockRefresh {
    /// §4.8: recompile weekly.
    public static let interval: TimeInterval = 7 * 24 * 60 * 60

    /// Due when we have never refreshed, or the interval has elapsed.
    public static func isDue(
        lastRefresh: Date?,
        now: Date,
        interval: TimeInterval = interval
    ) -> Bool {
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= interval
    }
}
