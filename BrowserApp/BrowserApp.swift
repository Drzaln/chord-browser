import BrowserStore
import BrowserUI
import SwiftUI
import os

@main
struct BrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppRootView(launch: appDelegate.launch)
                .onAppear { appDelegate.attachOcclusionObserver() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            BrowserCommands(launch: appDelegate.launch)
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

    var body: some View {
        switch launch {
        case .ready(let environment):
            RootView(store: environment.store)
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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { launch.store?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("Close Tab") {
                guard let store = launch.store, let id = store.selectedTabID else { return }
                store.closeTab(id)
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("Reload") { launch.store?.reload() }
                .keyboardShortcut("r", modifiers: .command)
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
