import ChordStore
import ChordUI
import SwiftUI
import os

@main
struct ChordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // `WindowGroup`, so Cmd+N opens a real second window (verified against
        // Arc, which this replicates). The reason it was a single `Window`
        // before — a URL handed to the app spawned a window whose `RootView`
        // ran `store.restore()` a second time on the same store — is handled by
        // the store now: `restore()` is guarded by `hasRestored`, and each
        // scene takes its own `WindowState` from `claimWindow()` rather than
        // sharing one.
        WindowGroup("Chord", id: "main") {
            AppRootView(
                launch: appDelegate.launch,
                commandBar: appDelegate.commandBar
            )
            .onAppear { appDelegate.attachOcclusionObserver() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            ChordCommands(
                launch: appDelegate.launch, commandBar: appDelegate.commandBar
            )
        }
    }
}

/// Either a running app or the reason it could not start. Making this explicit
/// keeps a persistence failure from turning into a launch crash (3.7).
enum Launch {
    case ready(AppEnvironment)
    case failed(String)

    /// The store is main-actor state, so it is only reachable from main-actor
    /// context — command actions and view bodies, never `Scene.body` itself.
    @MainActor
    var store: TabStore? {
        if case .ready(let environment) = self { return environment.store }
        return nil
    }

}

struct AppRootView: View {
    let launch: Launch
    let commandBar: CommandBarController?
    @Environment(\.openWindow) private var openWindow

    /// This scene's window state, taken from the store on first appearance: the
    /// primary for the first window, a fresh registered one for each Cmd+N.
    /// Held in `@State` so it is stable for the life of the window.
    @State private var windowState: WindowState?

    var body: some View {
        switch launch {
        case .ready(let environment):
            content(environment)
                .onAppear {
                    if windowState == nil { windowState = environment.store.claimWindow() }
                    // "Open Link in New Private Window" needs a window opened,
                    // and `openWindow` exists only in a scene's environment —
                    // the store marks the intent and this performs it. Set from
                    // every window, harmlessly: they all do the same thing.
                    environment.store.privateWindowPresenter = { openWindow(id: "main") }
                }
                // Restore is a *session* concern, not a window one, so only the
                // window that got the primary state kicks it off. `restore()` is
                // guarded against running twice anyway, but a second window
                // should not be asking in the first place — that ambiguity is
                // exactly what kept this app on a single `Window` before.
                .task {
                    guard windowState === environment.store.primaryWindow else { return }
                    await environment.store.restore()
                }
                .onDisappear {
                    if let windowState { environment.store.unregister(windowState) }
                }
        case .failed(let message):
            LaunchFailureView(message: message)
        }
    }

    /// Withheld until the window has its state — one frame, and it avoids
    /// every view below having to treat the window as optional.
    @ViewBuilder
    private func content(_ environment: AppEnvironment) -> some View {
        if let windowState {
            RootView(
                store: environment.store,
                windowState: windowState,
                downloads: environment.downloads,
                extensionHost: environment.extensionHost,
                extensions: environment.extensions,
                openCommandBar: { mode, query in
                    commandBar?.present(
                        over: NSApp.keyWindow,
                        windowState: windowState,
                        mode: mode,
                        initialQuery: query ?? ""
                    )
                }
            )
            #if DEBUG
            .overlay(DebugOverlay(store: environment.store, windowState: windowState))
            #endif
        } else {
            Color.clear
        }
    }
}

struct LaunchFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("The browser could not start")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(40)
        .frame(minWidth: 460, minHeight: 260)
    }
}

struct ChordCommands: Commands {
    let launch: Launch
    @Environment(\.openWindow) private var openWindow
    /// The focused window's state. `Commands` is built once for the app, so the
    /// items that act on a window must ask which one is focused rather than
    /// assume — see `FocusedWindowState`. Nil only if no browser window is
    /// focused, in which case those items are correctly disabled.
    @FocusedValue(\.windowState) private var windowState: WindowState?

    /// The store, when the app actually started. Every window shares it.
    private var store: TabStore? { launch.store }

    /// Runs `action` against the focused window, or does nothing when no browser
    /// window has focus. Every window-scoped menu item goes through this, so the
    /// "which window did the user mean" question is answered in exactly one
    /// place — it used to be answered by `NSApp.mainWindow`, i.e. guessed.
    private func withFocusedWindow(_ action: (TabStore, WindowState) -> Void) {
        guard let store, let windowState else { return }
        action(store, windowState)
    }

    /// Whether the focused window is private, for the items that make no sense
    /// there — Spaces, pinning, and History (which reads the active Space's
    /// history and would be a permanently empty list).
    private var isPrivateWindowFocused: Bool { windowState?.isPrivate == true }

    /// The address of the focused window's current tab, for `Cmd+L` — the same
    /// string the toolbar address button hands the bar. Falls back to the pane's
    /// stored URL when the engine has not reported one yet.
    private var currentURLString: String {
        guard let store, let windowState else { return "" }
        let tab = store.selectedTab(in: windowState)
        let runtime = tab.map { store.runtime(for: $0.focusedPaneID) }
        return runtime?.currentURL?.absoluteString
            ?? tab?.focusedPane.url.absoluteString
            ?? ""
    }

    /// Lives in the UI package, so it is owned by the delegate rather than by
    /// `AppEnvironment` — Store must not depend on UI.
    let commandBar: CommandBarController?

    var body: some Commands {
        // The standard app "Settings…" item — Cmd+, — opens the settings sheet
        // (clear browsing data + extensions) rather than a separate window, so
        // it lives inside the single browser window like the other sheets.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { windowState?.isSettingsPresented = true }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(windowState == nil)
        }
        CommandGroup(replacing: .newItem) {
            // Cmd+T opens the command bar, not a blank tab (4.4). A new tab is
            // one Enter away, and usually you wanted a destination anyway.
            Button("New Tab…") {
                commandBar?.toggle(over: NSApp.keyWindow, windowState: windowState, mode: .newTab)
            }
            .keyboardShortcut("t", modifiers: .command)

            // Same bar, aimed at the tab you are on — the conventional Cmd+L.
            // Without it, Cmd+T had to double as "replace this tab", which is
            // the one thing users never expect it to do.
            Button("Open Location…") {
                commandBar?.toggle(
                    over: NSApp.keyWindow,
                    windowState: windowState,
                    mode: .currentTab,
                    initialQuery: currentURLString
                )
            }
            .keyboardShortcut("l", modifiers: .command)

            // Cmd+N is New Window — Arc's binding, and the platform's. It was
            // bound to a blank tab only because there was no second window to
            // open; `newWindow` is SwiftUI's action for a `WindowGroup`.
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: .command)

            // Cmd+Shift+N is the private-window binding everywhere else, so it
            // takes it here too and the blank tab moves along to Cmd+Opt+N (it
            // already moved once, off Cmd+N, when multi-window landed). The
            // store is marked *before* the window opens: `claimWindow()` reads
            // the latch, because `openWindow(id:)` carries no value of its own.
            Button("New Private Window") {
                store?.markNextWindowPrivate()
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New Blank Tab") { withFocusedWindow { $0.newTab(in: $1) } }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandGroup(after: .newItem) {
            Button("Close Tab") {
                withFocusedWindow { store, window in
                    guard let id = window.selectedTabID else { return }
                    store.closeTab(id, in: window)
                }
            }
            .keyboardShortcut("w", modifiers: .command)

            // Cmd+Shift+T — the platform-wide "reopen the tab I just closed".
            Button("Reopen Closed Tab") { withFocusedWindow { $0.reopenLastClosedTab(in: $1) } }
                .keyboardShortcut("t", modifiers: [.command, .shift])

            Divider()

            // Most-recently-used tab switching (non-spec: user-requested, Arc
            // style). Ctrl+Tab / Ctrl+Shift+Tab are what every browser binds;
            // Cmd+1…9 is taken by Spaces here, so this is the only keyboard way
            // to step through tabs. Pressing Ctrl shows the MRU overlay; these
            // commands step it, and releasing Ctrl commits.
            Button("Next Tab") { withFocusedWindow { $0.selectNextTab(in: $1) } }
                .keyboardShortcut(.tab, modifiers: .control)

            Button("Previous Tab") { withFocusedWindow { $0.selectPreviousTab(in: $1) } }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

            // Cmd+D — Arc uses pinned tabs where other browsers bookmark, so the
            // bookmark key pins instead. Toggles, so the same key un-pins.
            Button("Pin or Unpin Tab") {
                withFocusedWindow { store, window in
                    guard let tab = store.selectedTab(in: window) else { return }
                    store.setPinned(!tab.placement.isPinned, tabID: tab.id)
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            // A private window has no pinned sections — the Space it would pin
            // into evaporates when the window closes.
            .disabled(isPrivateWindowFocused)

            Divider()

            // Split view (4.5). Opens the command bar to say *what* goes in the
            // new pane, the same way Cmd+T asks what goes in a new tab — a
            // blank pane just makes you type the destination afterwards. The
            // store still declines beyond four panes rather than replacing one.
            Button("Split Tab…") {
                commandBar?.toggle(over: NSApp.keyWindow, windowState: windowState, mode: .newPane)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Close Pane") {
                withFocusedWindow { store, window in
                    guard let tab = store.selectedTab(in: window) else { return }
                    store.closePane(tab.focusedPaneID, in: window)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift, .option])

            Divider()

            Button("Reload") { withFocusedWindow { $0.reload(in: $1) } }
                .keyboardShortcut("r", modifiers: .command)

            // Cmd+. — the platform's "stop". The reload button also becomes a
            // stop button while a page loads; this is the keyboard equivalent.
            Button("Stop Loading") { withFocusedWindow { $0.stopLoading(in: $1) } }
                .keyboardShortcut(".", modifiers: .command)
        }

        // Print the page (M6). Cmd+P, the platform's, replacing the default
        // print item so it targets the focused pane's web view rather than a
        // document the app does not have.
        CommandGroup(replacing: .printItem) {
            Button("Print…") { withFocusedWindow { $0.printSelectedPane(in: $1) } }
                .keyboardShortcut("p", modifiers: .command)
        }

        // Find-in-page (M6). Cmd+G / Cmd+Shift+G are the platform's, and they
        // work whether or not the field has focus — which is the point: you
        // find, click into the page, then keep stepping through matches.
        CommandGroup(after: .textEditing) {
            Button("Find…") { withFocusedWindow { $0.showFindBar(in: $1) } }
                .keyboardShortcut("f", modifiers: .command)

            Button("Find Next") { withFocusedWindow { $0.findNext(in: $1) } }
                .keyboardShortcut("g", modifiers: .command)

            Button("Find Previous") { withFocusedWindow { $0.findPrevious(in: $1) } }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            // Cmd+S. Arc's binding, and nothing here saves a document.
            Button("Toggle Sidebar") {
                windowState?.isSidebarCollapsed.toggle()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(windowState == nil)

            // Presentation mode hides all browser chrome so a screen-shared
            // window shows only the page — WebKit's native stand-in for "Share
            // this tab", which it cannot do. Cmd+Ctrl+S, a sidebar-family
            // mnemonic; Cmd+Ctrl+P is the debug overlay.
            Button(
                (windowState?.isPresentationMode ?? false)
                    ? "Exit Presentation Mode" : "Enter Presentation Mode"
            ) {
                windowState?.isPresentationMode.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(windowState == nil)
        }

        // Cmd+Y — the platform's "Show All History" (Safari/Chrome both use it),
        // so it needs no learning. Opens the History window.
        CommandMenu("History") {
            Button("Show History") { windowState?.isHistoryPresented = true }
                .keyboardShortcut("y", modifiers: .command)
                // History is per-Space, and a private Space records none — the
                // window would open on a list that is empty by construction.
                .disabled(windowState == nil || isPrivateWindowFocused)
        }

        CommandMenu("Spaces") {
            Button("New Space") { withFocusedWindow { $0.addSpace(in: $1) } }
                .disabled(isPrivateWindowFocused)

            Divider()

            // Cmd+1...9 (4.2). Bound unconditionally rather than to the current
            // Space list, so the shortcuts do not churn as Spaces are added;
            // the store ignores an index that does not exist.
            ForEach(1...9, id: \.self) { position in
                Button("Space \(position)") {
                    withFocusedWindow { store, window in
                        SpaceSwitchAnimator.switchSpace(
                            toIndex: position - 1, in: window, store: store,
                            reduceMotion: NSWorkspace.shared
                                .accessibilityDisplayShouldReduceMotion
                        )
                    }
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(position)")), modifiers: .command
                )
                // A private window is locked to its own Space, so there is
                // nowhere for Cmd+1…9 to go.
                .disabled(isPrivateWindowFocused)
            }
        }
    }
}
