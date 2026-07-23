import AppKit
import BrowserStore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.rizal.browser", category: "app")
    private static let signposter = OSSignposter(
        subsystem: "com.rizal.browser", category: "lifecycle"
    )

    /// Built once, at launch, and passed down by hand (3.6).
    let launch: Launch

    override init() {
        let state = Self.signposter.beginInterval("launch")
        do {
            launch = .ready(try AppEnvironment.live())
        } catch {
            Self.log.fault("launch failed: \(String(describing: error))")
            launch = .failed(String(describing: error))
        }
        Self.signposter.endInterval("launch", state)
        super.init()
    }

    /// While the window is not visible the app should approach zero CPU: the
    /// engine stops fetching favicons and pending state is flushed (6.3).
    func attachOcclusionObserver() {
        guard let store = launch.store else { return }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Delivered on the main queue. The notification itself is not
            // Sendable, so occlusion is recomputed from the app's windows
            // instead — which is the question we actually care about: is *any*
            // window visible?
            MainActor.assumeIsolated {
                let anyVisible = NSApp.windows.contains {
                    $0.occlusionState.contains(.visible)
                }
                store.setOccluded(!anyVisible)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        launch.store?.flushSave()
    }
}
