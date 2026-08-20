import Foundation

/// Injected so the ephemeral sweep (M3) and recency ranking are testable without
/// waiting on wall-clock time.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}
