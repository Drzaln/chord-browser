import Foundation

/// Work that waits for the first page to paint, but not for ever (c1k.7).
@MainActor
enum LaunchDeferral {
    /// Returns when `event` does or `timeout` passes, whichever is first. A
    /// launch with no tabs, or a slow first page, never paints soon.
    static func first(_ event: @escaping @MainActor () async -> Void, orAfter timeout: Duration) async {
        let once = Once()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            once.done = done
            Task { @MainActor in await event(); once.finish() }
            Task { @MainActor in try? await Task.sleep(for: timeout); once.finish() }
        }
    }

    @MainActor
    private final class Once {
        var done: CheckedContinuation<Void, Never>?
        func finish() {
            done?.resume()
            done = nil
        }
    }
}
