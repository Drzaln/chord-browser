import Foundation

/// What Chord may add on top of WebKit, held by tests (c1k.8). Raising one
/// is a deliberate change: edit the number here and say why in the commit.
/// docs/perf/BUDGETS.md explains each.
public enum PerfBudget {
    /// User scripts on a default tab (no developer mode, overrides or
    /// extensions): the every-frame bundle, the store relay, password forms.
    public static let userScripts = 3
    /// Of those, the ones parsed in every frame, iframes included.
    public static let everyFrameScripts = 1
    /// Their total source size.
    public static let userScriptBytes = 45_000

    /// Live intervals two seconds after a plain page loads.
    public static let intervalsOnAPlainPage = 0
    /// On YouTube: the ad check's 2 s backup tick.
    public static let intervalsOnYouTube = 1

    /// The setInterval calls reviewed and allowed, by script, with why.
    /// Anything else that repeats must wait for an event instead.
    public static let reviewedIntervals: [String: (count: Int, why: String)] = [
        "YouTubeAdBlocker": (2, "four a second only while an ad is up; a 2 s backup for missed events"),
        "GeolocationBridge": (1, "only while a page watches the position"),
    ]

    public static let failure = "over the perf budget: see docs/perf/BUDGETS.md"
}
