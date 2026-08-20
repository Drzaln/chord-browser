import AppKit
import ChordStore
import ChordUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.rizal.chord", category: "app")
    private static let signposter = OSSignposter(
        subsystem: "com.rizal.chord", category: "lifecycle"
    )

    /// Built once, at launch, and passed down by hand (3.6).
    let launch: Launch

    /// Built once and reused; rebuilding the panel per invocation would spend
    /// the command bar's 50 ms budget on view construction (6.1).
    private(set) lazy var commandBar: CommandBarController? = {
        guard let store = launch.store else { return nil }
        return CommandBarController(store: store)
    }()

    /// Little Chord (4.6). Built lazily for the same reason as the command bar.
    /// Also hosts the Peek panel — a link clicked in a favourite/pinned tab is
    /// the same floating, promotable panel (non-spec: user-requested).
    private(set) lazy var littleChord: LittleChordController? = {
        guard let store = launch.store else { return nil }
        return LittleChordController(store: store)
    }()

    /// Web notifications bridged to macOS Notification Center (non-spec:
    /// user-requested). Owns the `UNUserNotificationCenter`; the store forwards
    /// the engine's polyfill calls here.
    private(set) lazy var notifications: NotificationController = {
        let controller = NotificationController()
        controller.onClick = { [weak self] jsID, paneID in
            self?.launch.store?.handleNotificationClick(jsID: jsID, paneID: paneID)
            // Bring Chord forward so the focused tab is actually visible.
            NSApp.activate(ignoringOtherApps: true)
        }
        return controller
    }()

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

    /// Locks the password vault when the user has demonstrably walked away (V7).
    ///
    /// Three signals, because no one of them covers the others: closing the lid
    /// or the machine sleeping (`willSleep`), the display sleeping on its own
    /// (`screensDidSleep`, which is also what a "require password after screen
    /// saver" lock looks like from in here), and fast user switching
    /// (`sessionDidResignActive`). The idle timeout in Settings is the fourth,
    /// and it lives in the store because it is arithmetic, not an event.
    ///
    /// `com.apple.screenIsLocked` is the direct screen-lock signal and is
    /// observed too, but it is a *distributed* notification and a sandboxed app
    /// is not guaranteed to receive it — which is why the workspace signals
    /// above are the ones being relied on rather than a nicety beside it.
    func attachVaultLockObservers() {
        guard let store = launch.store else { return }

        let workspace = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { store.lockVault() }
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { store.lockVault() }
        }
    }

    /// Turns off native window tabbing.
    ///
    /// We have our own vertical tabs; the system "Show Tab Bar" item and its
    /// window-tab shortcuts are confusing next to them, and tabbing adds its own
    /// claim on Cmd+T.
    func disableWindowTabbing() {
        for window in NSApp.windows where window.tabbingMode != .disallowed {
            window.tabbingMode = .disallowed
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        disableWindowTabbing()
        attachVaultLockObservers()

        // "Open in Little Chord" from a link's context menu routes here: the engine
        // asks the store, the store forwards to this presenter, which owns the
        // panel. Set once — the closure holds the controller lazily.
        launch.store?.littleChordPresenter = { [weak self] url in
            self?.littleChord?.present(url: url)
        }

        // The swipe-to-close path in the engine (a rightward swipe on a panel
        // page that has nothing to undo) asks the store, which forwards here to
        // dismiss the panel — the one browser surface that has no toolbar.
        launch.store?.littleChordDismisser = { [weak self] in
            self?.littleChord?.dismiss()
        }

        // A plain click on a link inside a favourite/pinned tab routes here:
        // engine → store (placement check) → this presenter. The panel lives in
        // the Space the click came from, so it arrives already logged in.
        launch.store?.peekPresenter = { [weak self] url, spaceID in
            self?.littleChord?.present(url: url, inSpace: spaceID)
        }

        // Web notifications route engine (polyfill) → store → these hooks. The
        // presenter posts to Notification Center; the requester drives the OS
        // authorization prompt and reports the result back to the page.
        launch.store?.notificationPresenter = { [weak self] request, paneID in
            self?.notifications.present(request, fromPane: paneID)
        }
        // The OS-authorization backstop: web Notifications only reach Notification
        // Center if the app itself is authorized. The store calls this the first
        // time a site is allowed (per-origin consent is handled in the store).
        launch.store?.notificationPermissionRequester = { [weak self] in
            await self?.notifications.requestAuthorization() ?? false
        }

        // Windows created later (and SwiftUI recreating one) must get the same
        // treatment, or the shortcut breaks again the next time.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.disableWindowTabbing()
            }
        }
    }

    /// A web link from another app opens in the Little Chord panel (4.6).
    ///
    /// The panel is deliberately *not* a tab: most links from other apps are a
    /// glance, and promoting is one keystroke away.
    func application(_ application: NSApplication, open urls: [URL]) {
        let webLinks = urls.filter { $0.scheme == "http" || $0.scheme == "https" }
        guard let url = webLinks.first else { return }

        if webLinks.count > 1 {
            // Several at once is a "open all of these" gesture, not a peek. They
            // land in the window the user last focused (the same window Little Chord
            // promotion targets), falling back to the primary at a cold launch.
            for extra in webLinks.dropFirst() {
                guard let store = launch.store else { break }
                store.newTab(url: extra, in: store.focusedNonPrivateWindow)
            }
        }
        littleChord?.present(url: url)
    }

    /// The Little Chord panel can be the only window there is (4.6), so the app
    /// must not quit when the main window closes while a panel is up.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // littleChord?.isVisible != true
        return false
    }

    /// Defers termination until session state is on disk.
    ///
    /// `applicationWillTerminate` is too late to be useful here: it cannot wait,
    /// and the process is gone before a detached write task is ever scheduled.
    /// A force-quit still loses whatever happened since the last deactivation —
    /// which is precisely why state is captured on every tab switch and on
    /// occlusion rather than only on the way out.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = launch.store else { return .terminateNow }

        Task {
            await store.flushInteractionState()
            await store.flushSaveAndWait()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
