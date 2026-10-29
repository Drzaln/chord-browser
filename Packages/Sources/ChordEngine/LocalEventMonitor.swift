import AppKit
import Synchronization

/// An `NSEvent` local monitor that removes itself when it is released.
///
/// A local monitor is app-wide and runs on every event of its kind until it is
/// removed. Its owners still drop it in their `stop()`, but one whose owner went
/// away without stopping (a view that appeared twice, say) would otherwise run
/// for the life of the app, with nothing left able to remove it.
public final class LocalEventMonitor {
    private static let liveCount = Atomic<Int>(0)

    /// How many are installed, for tests.
    public static var live: Int { liveCount.load(ordering: .relaxed) }

    private let token: Any?

    @MainActor
    public init(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) {
        token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
        if token != nil { Self.liveCount.add(1, ordering: .relaxed) }
    }

    deinit {
        guard let token else { return }
        NSEvent.removeMonitor(token)
        Self.liveCount.subtract(1, ordering: .relaxed)
    }
}
