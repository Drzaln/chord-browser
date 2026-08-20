import AppKit

/// Restores double-click-to-zoom on the top strip of the window.
///
/// The behaviour was lost when the content card was extended over the titlebar
/// (`ignoresSafeArea(.container, edges: .top)`, so the tint reaches the top
/// edge): AppKit handles a titlebar double-click on the *titlebar view*, and the
/// content now covers it. This is a local `.leftMouseDown` monitor rather than
/// an overlay view on purpose — it intercepts only the double-click in the top
/// strip and never blocks an ordinary click on the page beneath, which an
/// always-present hit-testing view would.
///
/// Dragging the window by the top already works; only the double-click was lost.
@MainActor
final class TitlebarDoubleClickMonitor {
    private var monitor: Any?

    /// The main window. A double-click in a floating panel is not a zoom.
    weak var window: NSWindow?

    /// Height of the top strip treated as titlebar, matching the clearance the
    /// sidebar reserves for the traffic lights.
    var stripHeight: CGFloat = Metrics.titlebarInset

    /// Left margin kept clear of the traffic lights, so double-clicking near them
    /// does not zoom.
    private let trafficLightMargin: CGFloat = 80

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil  // consumed: the double-click zooms rather than reaching the page
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns true when the event was a titlebar-strip double-click and has been
    /// handled.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.clickCount == 2,
              let window, event.window === window,
              let contentView = window.contentView
        else { return false }

        let point = event.locationInWindow  // window coordinates, bottom-left origin
        guard point.y >= contentView.bounds.height - stripHeight,
              point.x > trafficLightMargin
        else { return false }

        performDoubleClickAction(window)
        return true
    }

    /// Honours the system "double-click a window's title bar to" preference,
    /// defaulting to zoom (fill) — which is what the setting is set to for most
    /// people, and what a missing/unreadable value should degrade to.
    private func performDoubleClickAction(_ window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}
