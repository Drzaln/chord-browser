import BrowserStore
import BrowserUI
import SwiftUI
import os

@main
struct BrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // `Window`, not `WindowGroup`: this is a single-window browser (1), and
        // a group spawns a *second* window when a URL is handed to the app —
        // whose RootView then runs `store.restore()` again on the same store.
        Window("Browser", id: "main") {
            AppRootView(launch: appDelegate.launch, commandBar: appDelegate.commandBar)
                .onAppear { appDelegate.attachOcclusionObserver() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            BrowserCommands(
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

    var body: some View {
        switch launch {
        case .ready(let environment):
            RootView(
                store: environment.store,
                downloads: environment.downloads,
                extensionHost: environment.extensionHost,
                openCommandBar: { mode, query in
                    commandBar?.present(
                        over: NSApp.mainWindow, mode: mode, initialQuery: query ?? ""
                    )
                }
            )
                #if DEBUG
                .overlay(DebugOverlay(store: environment.store))
                #endif
        case .failed(let message):
            LaunchFailureView(message: message)
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

struct BrowserCommands: Commands {
    let launch: Launch
    /// Lives in the UI package, so it is owned by the delegate rather than by
    /// `AppEnvironment` — Store must not depend on UI.
    let commandBar: CommandBarController?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Cmd+T opens the command bar, not a blank tab (4.4). A new tab is
            // one Enter away, and usually you wanted a destination anyway.
            Button("New Tab…") {
                commandBar?.toggle(over: NSApp.mainWindow, mode: .newTab)
            }
            .keyboardShortcut("t", modifiers: .command)

            // Same bar, aimed at the tab you are on — the conventional Cmd+L.
            // Without it, Cmd+T had to double as "replace this tab", which is
            // the one thing users never expect it to do.
            Button("Open Location…") {
                commandBar?.toggle(over: NSApp.mainWindow, mode: .currentTab)
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("New Blank Tab") { launch.store?.newTab() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("Close Tab") {
                guard let store = launch.store, let id = store.selectedTabID else { return }
                store.closeTab(id)
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            // Split view (4.5). Opens the command bar to say *what* goes in the
            // new pane, the same way Cmd+T asks what goes in a new tab — a
            // blank pane just makes you type the destination afterwards. The
            // store still declines beyond four panes rather than replacing one.
            Button("Split Tab…") {
                commandBar?.toggle(over: NSApp.mainWindow, mode: .newPane)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Close Pane") {
                guard let store = launch.store, let tab = store.selectedTab else { return }
                store.closePane(tab.focusedPaneID)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift, .option])

            Divider()

            Button("Reload") { launch.store?.reload() }
                .keyboardShortcut("r", modifiers: .command)
        }

        // Print the page (M6). Cmd+P, the platform's, replacing the default
        // print item so it targets the focused pane's web view rather than a
        // document the app does not have.
        CommandGroup(replacing: .printItem) {
            Button("Print…") { launch.store?.printSelectedPane() }
                .keyboardShortcut("p", modifiers: .command)
        }

        // Find-in-page (M6). Cmd+G / Cmd+Shift+G are the platform's, and they
        // work whether or not the field has focus — which is the point: you
        // find, click into the page, then keep stepping through matches.
        CommandGroup(after: .textEditing) {
            Button("Find…") { launch.store?.showFindBar() }
                .keyboardShortcut("f", modifiers: .command)

            Button("Find Next") { launch.store?.findNext() }
                .keyboardShortcut("g", modifiers: .command)

            Button("Find Previous") { launch.store?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            // Cmd+S. Arc's binding, and nothing here saves a document.
            Button("Toggle Sidebar") {
                guard let store = launch.store else { return }
                store.isSidebarCollapsed.toggle()
            }
            .keyboardShortcut("s", modifiers: .command)
        }

        CommandMenu("Spaces") {
            Button("New Space") { launch.store?.addSpace() }

            Divider()

            // Cmd+1...9 (4.2). Bound unconditionally rather than to the current
            // Space list, so the shortcuts do not churn as Spaces are added;
            // the store ignores an index that does not exist.
            ForEach(1...9, id: \.self) { position in
                Button("Space \(position)") {
                    launch.store?.selectSpace(atIndex: position - 1)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(position)")), modifiers: .command
                )
            }
        }
    }
}
