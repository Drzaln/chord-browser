import ChordCore
import ChordStore
import ChordUI
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os

/// The real entry point. `Chord --mcp-stdio` is the MCP helper an agent's
/// client launches (0mu): it bridges stdio to the running app and exits,
/// before any of AppKit, the store or a window exists. Anything else is the
/// browser.
@main
enum ChordMain {
    static func main() {
        if CommandLine.arguments.dropFirst().contains(AgentBridge.stdioFlag) {
            exit(AgentBridge.runStdio())
        }
        ChordApp.main()
    }
}

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
            // A link from another app goes to AppDelegate (Little Chord or a
            // routed Space). Without this, SwiftUI also opened a new window
            // for every link it was handed (63d); an open window takes it.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
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
                    // Closing the last live favourite/Pinned tile leaves the
                    // window blank (Arc); offer the command bar right away so a
                    // destination is one keystroke away, like Cmd+T.
                    environment.store.closeLeftBlankPresenter = { window in
                        // Already offered (e.g. a Space switch in a blank
                        // window): leave the open bar alone rather than reset the
                        // query the user is typing.
                        guard commandBar?.isVisible != true else { return }
                        commandBar?.present(
                            over: NSApp.keyWindow,
                            windowState: window,
                            mode: .newTab
                        )
                    }
                    // The window shows a tab again (left a blank Space for one
                    // with content, or picked a tab): drop the blank bar.
                    environment.store.closeLeftBlankDismisser = { _ in
                        commandBar?.dismiss()
                    }
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
                bookmarks: environment.bookmarks,
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

    /// Two-way binding for the Developer Mode toggle in the Develop menu. The
    /// store is the source of truth; the menu is a convenience that writes
    /// through to it (and thus to the engine) immediately.
    private var developerModeBinding: Binding<Bool> {
        Binding(
            get: { store?.developerMode ?? false },
            set: { store?.developerMode = $0 }
        )
    }

    /// Shows a confirmation toast in the focused window's top right (non-spec:
    /// user-requested). A no-op when no browser window is focused.
    private func toast(_ message: String, icon: String = "checkmark.circle.fill") {
        windowState?.showToast(message, icon: icon)
    }

    /// The focused window's current page URL, already computed for Cmd+L; used
    /// by the "Copy URL" command.
    private func copyCurrentURL() {
        let url = currentURLString
        guard !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        toast("Copied URL", icon: "link")
    }

    /// Zoom plus a percentage toast, so a menu action that has no other visible
    /// feedback still says what it did.
    private func zoom(_ message: String, icon: String, _ mutate: (TabStore) -> Void) {
        guard let store else { return }
        mutate(store)
        let percent = Int((store.pageZoom * 100).rounded())
        toast("\(message) \(percent)%", icon: icon)
    }

    /// File → Import Bookmarks…: pick a Netscape-format export, show the
    /// dry-run counts, then write Pinned tabs and folders through the store.
    /// The picker is security-scoped for exactly the read; the parser is pure,
    /// so the file is closed before anything is written.
    @MainActor
    private func importBookmarks(into window: WindowState) {
        guard let store else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Import"
        panel.message = "Choose a bookmarks HTML file exported by another browser."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            presentImportError(
                "Could not read “\(url.lastPathComponent)”",
                detail: error.localizedDescription
            )
            return
        }

        let plan = NetscapeBookmarkParser.parse(data)
        guard !plan.entries.isEmpty || !plan.folders.isEmpty else {
            presentImportError(
                "No bookmarks found",
                detail: plan.skippedCount == 0
                    ? "Chord could not find any folders or http(s) bookmarks in that file."
                    : "\(plan.skippedCount) entries were skipped. "
                        + "Is this a Netscape-format bookmarks export?"
            )
            return
        }

        let spaceName = store.activeSpace(in: window)?.name ?? "this Space"
        let confirmation = NSAlert()
        let noun = plan.entryCount == 1 ? "bookmark" : "bookmarks"
        confirmation.messageText = "Import \(plan.entryCount) \(noun)?"
        var details = [
            "Adds \(plan.entryCount) bookmarks to \(plan.folderCount) folders "
                + "in “\(spaceName)”.",
            "Root-level bookmarks become Pinned tabs; nested folders are "
                + "flattened as “Parent / Child”.",
        ]
        if plan.skippedCount > 0 {
            details.append("\(plan.skippedCount) entries will be skipped.")
        }
        if plan.depthLimitReached {
            details.append(
                "Folders deeper than \(NetscapeBookmarkParser.maximumFolderDepth) "
                    + "levels will be skipped."
            )
        }
        confirmation.informativeText = details.joined(separator: "\n")
        confirmation.addButton(withTitle: "Import")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        let result = store.importBookmarks(plan, in: window)
        if result.entriesAdded == 0 && result.foldersCreated == 0 {
            toast("Nothing new to import", icon: "bookmark")
        } else {
            let count = result.entriesAdded
            toast("Imported \(count) bookmark\(count == 1 ? "" : "s")", icon: "bookmark")
        }
    }

    private func presentImportError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// File → Import from Arc…: pick Arc's data folder (or its
    /// `StorableSidebar.json`), show the per-Space dry-run counts, then write
    /// Spaces, Pins and favourites through the store.
    ///
    /// The picker is security-scoped for exactly the read. Parsing is pure and
    /// finishes before the first write, so cancel, a corrupt file, or a file
    /// that is not Arc's sidebar leaves the profile untouched.
    @MainActor
    private func importFromArc(into window: WindowState) {
        guard let store else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.folder, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Import"
        panel.message = "Choose Arc's data folder, or its StorableSidebar.json."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        let scoped = chosen.startAccessingSecurityScopedResource()
        defer { if scoped { chosen.stopAccessingSecurityScopedResource() } }

        guard let file = Self.arcSidebarFile(startingAt: chosen) else {
            presentImportError(
                "No Arc sidebar found",
                detail: "Chord looks for StorableSidebar.json in the folder you "
                    + "choose. Pick Arc's data folder — usually "
                    + "~/Library/Application Support/Arc — or the file itself."
            )
            return
        }

        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 32 << 20 else {
            presentImportError(
                "Arc's sidebar is too large",
                detail: "StorableSidebar.json is larger than 32 MB, which is not "
                    + "a sidebar Chord can read safely."
            )
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            presentImportError(
                "Could not read “\(file.lastPathComponent)”",
                detail: error.localizedDescription
            )
            return
        }

        guard let plan = ArcSidebarParser.parse(data) else {
            presentImportError(
                "Not an Arc sidebar",
                detail: "“\(file.lastPathComponent)” is not a readable Arc "
                    + "StorableSidebar.json. Nothing was imported."
            )
            return
        }
        guard !plan.spaces.isEmpty else {
            presentImportError(
                "No Arc Spaces found",
                detail: "The file is readable, but it holds no Spaces to import."
            )
            return
        }

        let confirmation = NSAlert()
        confirmation.messageText = plan.spaceCount == 1
            ? "Import 1 Arc Space?"
            : "Import \(plan.spaceCount) Arc Spaces?"
        confirmation.informativeText = importArcSummary(plan)
        confirmation.addButton(withTitle: "Import")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        let result = store.importArc(plan, in: window)
        guard result.didWriteAnything else {
            toast("Nothing new to import", icon: "square.and.arrow.down")
            return
        }

        var parts: [String] = []
        if result.pinsAdded > 0 {
            parts.append("\(result.pinsAdded) pin\(result.pinsAdded == 1 ? "" : "s")")
        }
        if result.favouritesAdded > 0 {
            parts.append(
                "\(result.favouritesAdded) "
                    + "favourite\(result.favouritesAdded == 1 ? "" : "s")"
            )
        }
        if result.spacesCreated > 0 {
            parts.append(
                "\(result.spacesCreated) space\(result.spacesCreated == 1 ? "" : "s")"
            )
        }
        if parts.isEmpty {
            parts.append(
                "\(result.foldersCreated) "
                    + "folder\(result.foldersCreated == 1 ? "" : "s")"
            )
        }
        toast("Imported " + parts.joined(separator: ", "), icon: "square.and.arrow.down")
    }

    /// The dry-run text: one line per Space with what it will contribute, then
    /// the totals and every class of dropped item. Shown before any write.
    private func importArcSummary(_ plan: ArcImportPlan) -> String {
        var lines: [String] = []
        let listed = plan.spaces.prefix(6)
        for space in listed {
            var counts = ["\(space.pinned.count) pinned"]
            if !space.favourites.isEmpty {
                counts.append("\(space.favourites.count) favourites")
            }
            if !space.folders.isEmpty {
                counts.append("\(space.folders.count) folders")
            }
            lines.append("• \(space.name) — \(counts.joined(separator: ", "))")
        }
        if plan.spaces.count > listed.count {
            lines.append("… and \(plan.spaces.count - listed.count) more")
        }

        lines.append("")
        lines.append(
            "\(plan.itemCount) page\(plan.itemCount == 1 ? "" : "s") in all. "
                + "Spaces with the same name are reused, and only http(s) pages "
                + "are imported. Passwords and cookies are never read."
        )
        if plan.flattenedFolderCount > 0 {
            lines.append(
                "\(plan.flattenedFolderCount) nested "
                    + "folder\(plan.flattenedFolderCount == 1 ? " is" : "s are") "
                    + "flattened as “Parent / Child”."
            )
        }
        if plan.mergedFolderCount > 0 {
            lines.append(
                "\(plan.mergedFolderCount) same-named "
                    + "folder\(plan.mergedFolderCount == 1 ? " merges" : "s merge") "
                    + "into one."
            )
        }
        if plan.skippedCount > 0 {
            lines.append(
                "\(plan.skippedCount) item\(plan.skippedCount == 1 ? "" : "s") "
                    + "will be skipped (arc://, extensions, files, and broken URLs)."
            )
        }
        if plan.credentialsStripped > 0 {
            lines.append(
                "\(plan.credentialsStripped) URL"
                    + "\(plan.credentialsStripped == 1 ? " had" : "s had") embedded "
                    + "credentials removed."
            )
        }
        if plan.depthLimitReached {
            lines.append(
                "Folders nested deeper than "
                    + "\(ArcSidebarParser.maximumFolderDepth) levels are skipped."
            )
        }
        if plan.itemLimitReached {
            lines.append(
                "Arc's sidebar is larger than the import limit; later items "
                    + "are left behind."
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Arc keeps `StorableSidebar.json` at the top of its data folder; some
    /// builds nest it one level down with the profile. A chosen file is used as
    ///-is.
    private static func arcSidebarFile(startingAt url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        else { return nil }
        guard isDirectory.boolValue else { return url }

        let candidates = [
            url.appendingPathComponent("StorableSidebar.json"),
            url.appendingPathComponent("Arc/StorableSidebar.json"),
            url.appendingPathComponent("User Data/Default/StorableSidebar.json"),
            url.appendingPathComponent("User Data/StorableSidebar.json"),
            url.appendingPathComponent("Default/StorableSidebar.json"),
        ]
        return candidates.first { candidate in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: candidate.path, isDirectory: &isDirectory
            ) && !isDirectory.boolValue
        }
    }

    /// File → Import Passwords…: pick a Chromium browser's `Login Data`,
    /// decrypt with its Safe Storage key, show the per-browser/profile dry run,
    /// then write through the existing vault.
    ///
    /// The picker is security-scoped for exactly the read. The importer copies
    /// the database to a private temp directory, reads the copy, and deletes it
    /// before returning; no secret is present in the preview, and Cancel never
    /// reaches the write path.
    @MainActor
    private func importPasswords(into window: WindowState) {
        guard let store else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Import"
        panel.message =
            "Choose a Chromium browser's “Login Data” file inside a profile "
            + "folder — for example Google/Chrome/Default/Login Data."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let scoped = url.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            // A profile in its usual place identifies its browser from the
            // path. A copied or throwaway profile (`--user-data-dir=/tmp/...`)
            // does not, and picking a Keychain service without knowing the
            // browser would be a guess — ask instead.
            let chosenBrowser: ChromiumBrowser?
            if ChromiumBrowser.detect(loginDataAt: url) == nil {
                guard let picked = askWhichBrowserSavedThePasswords() else { return }
                chosenBrowser = picked
            } else {
                chosenBrowser = nil
            }

            let preview: ChromiumPasswordImportPreview
            switch await store.previewPasswordImport(
                from: url, in: window, browser: chosenBrowser
            ) {
            case .success(let value):
                preview = value
            case .failure(let error):
                presentImportError(error.title, detail: error.message)
                return
            }
            // Cancel leaves the derived key nowhere: the preview is dropped at
            // the end of this scope, and `apply` invalidates it as well.
            defer { preview.invalidate() }

            let confirmation = NSAlert()
            confirmation.messageText = preview.hasAnythingToWrite
                ? "Import passwords from \(preview.source.browser.displayName)?"
                : "Nothing to import from \(preview.source.browser.displayName)"
            confirmation.informativeText = passwordImportSummary(preview)
            if preview.hasAnythingToWrite {
                confirmation.addButton(withTitle: "Import")
                confirmation.addButton(withTitle: "Cancel")
                guard confirmation.runModal() == .alertFirstButtonReturn else { return }

                let result = await store.applyPasswordImport(preview)
                if result.failed > 0 {
                    toast(
                        "Imported \(result.imported) login"
                            + "\(result.imported == 1 ? "" : "s"), "
                            + "\(result.failed) failed",
                        icon: "exclamationmark.triangle"
                    )
                } else if result.imported == 0 {
                    toast("Nothing new to import", icon: "key.fill")
                } else {
                    var message =
                        "Imported \(result.imported) login"
                        + "\(result.imported == 1 ? "" : "s")"
                    if result.importedUsernameOnly > 0 {
                        message +=
                            " (\(result.importedUsernameOnly) username"
                            + "\(result.importedUsernameOnly == 1 ? "" : "s") only)"
                    }
                    toast(message, icon: "key.fill")
                }
            } else {
                confirmation.addButton(withTitle: "OK")
                confirmation.runModal()
            }
        }
    }

    /// Asks which browser wrote a profile picked outside its usual folder.
    /// The answer selects the Keychain service, so it is never inferred from a
    /// folder name; Cancel imports nothing.
    private func askWhichBrowserSavedThePasswords() -> ChromiumBrowser? {
        let alert = NSAlert()
        alert.messageText = "Which browser saved these passwords?"
        alert.informativeText =
            "Chord reads the browser's Safe Storage key from your Keychain. "
            + "This profile is outside the usual browser folder, so the browser "
            + "cannot be told from the path."
        let choices = ChromiumBrowser.known
        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false
        )
        popup.addItems(withTitles: choices.map(\.displayName))
        if let chrome = choices.firstIndex(where: { $0.id == "chrome" }) {
            popup.selectItem(at: chrome)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        guard choices.indices.contains(index) else { return nil }
        return choices[index]
    }

    /// The dry-run text: what the file is, what will be written, and every
    /// class of row that will not be. No password and no ciphertext appears.
    private func passwordImportSummary(_ preview: ChromiumPasswordImportPreview) -> String {
        var lines = [
            "\(preview.source.browser.displayName) — profile "
                + "“\(preview.source.profileName)”",
            "",
        ]

        lines.append(
            "\(preview.importCount) login\(preview.importCount == 1 ? "" : "s") "
                + "will be imported: \(preview.withSecretCount) with a password, "
                + "\(preview.usernameOnlyCount) username-only."
        )
        if preview.alreadyPresentCount > 0 {
            lines.append(
                "\(preview.alreadyPresentCount) already saved in Chord; existing "
                    + "passwords are never overwritten."
            )
        }
        if preview.skippedCount > 0 {
            lines.append("\(preview.skippedCount) row\(preview.skippedCount == 1 ? "" : "s") skipped:")
            for reason in ChromiumPasswordSkipReason.allCases
            where reason != .alreadyPresent {
                let count = preview.skippedByReason[reason] ?? 0
                guard count > 0 else { continue }
                lines.append("  • \(count) — \(reason.label)")
            }
        }
        if preview.undecryptableCount > 0 {
            lines.append(
                "\(preview.undecryptableCount) could not be decrypted:"
            )
            for (reason, count) in preview.undecryptableByReason.sorted(by: {
                $0.key.explanation < $1.key.explanation
            }) {
                lines.append("  • \(count) — \(reason.explanation)")
            }
        }

        let sample = preview.items.filter {
            $0.disposition == .importSecret || $0.disposition == .importUsernameOnly
        }
        if !sample.isEmpty {
            lines.append("")
            for item in sample.prefix(6) {
                let host = URL(string: item.origin)?.host ?? item.origin
                lines.append("• \(host) — \(item.username)")
            }
            if sample.count > 6 {
                lines.append("… and \(sample.count - 6) more")
            }
        }

        lines.append("")
        lines.append(
            "Only HTTPS logins with a username are kept; file:, extension:, and "
                + "plain-HTTP entries are refused. The database was read from a "
                + "private temporary copy, which has already been deleted. Nothing "
                + "is written until you click Import."
        )
        return lines.joined(separator: "\n")
    }

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
            Button("New Window") {
                openWindow(id: "main")
                toast("New window opened", icon: "macwindow")
            }
                .keyboardShortcut("n", modifiers: .command)

            // Cmd+Shift+N is the private-window binding everywhere else, so it
            // takes it here too and the blank tab moves along to Cmd+Opt+N (it
            // already moved once, off Cmd+N, when multi-window landed). The
            // store is marked *before* the window opens: `claimWindow()` reads
            // the latch, because `openWindow(id:)` carries no value of its own.
            Button("New Private Window") {
                store?.markNextWindowPrivate()
                openWindow(id: "main")
                toast("New private window opened", icon: "hand.raised")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New Blank Tab") {
                withFocusedWindow { store, window in
                    store.newTab(in: window)
                    toast("New tab opened", icon: "plus.square.on.square")
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Divider()

            Button("Copy URL") { copyCurrentURL() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(currentURLString.isEmpty)

            Divider()

            // File → Import Bookmarks…: Netscape-format HTML from any browser,
            // with a dry-run count before anything is written. A private
            // window's Space is not persisted, so there is nowhere to keep an
            // imported bookmark.
            Button("Import Bookmarks…") {
                guard let windowState else { return }
                importBookmarks(into: windowState)
            }
            .disabled(windowState == nil || isPrivateWindowFocused)

            Divider()

            // File → Import from Arc…: Arc's StorableSidebar.json, with a
            // per-Space dry run before anything is written. Disabled in a
            // private window, whose Space and its pins evaporate on close.
            Button("Import from Arc…") {
                guard let windowState else { return }
                importFromArc(into: windowState)
            }
            .disabled(windowState == nil || isPrivateWindowFocused)

            // File → Import Passwords…: a Chromium browser's Login Data,
            // decrypted with its Safe Storage key and written through the
            // existing vault. Same dry-run-then-confirm shape as the other
            // imports; disabled in a private window.
            Button("Import Passwords…") {
                guard let windowState else { return }
                importPasswords(into: windowState)
            }
            .disabled(windowState == nil || isPrivateWindowFocused)
        }
        CommandGroup(after: .newItem) {
            Button("Close Tab") {
                withFocusedWindow { store, window in
                    guard let id = window.selectedTabID else { return }
                    store.closeTab(id, in: window)
                    toast("Tab closed", icon: "xmark.square")
                }
            }
            .keyboardShortcut("w", modifiers: .command)

            // Cmd+Shift+T — the platform-wide "reopen the tab I just closed".
            Button("Reopen Closed Tab") {
                withFocusedWindow { store, window in
                    store.reopenLastClosedTab(in: window)
                    toast("Reopened tab", icon: "arrow.uturn.backward")
                }
            }
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

            Button("Reload") {
                withFocusedWindow { store, window in
                    store.reload(in: window)
                    toast("Reloaded", icon: "arrow.clockwise")
                }
            }
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
        //
        // While Settings is up, Cmd+F means "find a setting": the sheet takes
        // the key for its own search field instead of opening find-in-page
        // behind it (899.7).
        CommandGroup(after: .textEditing) {
            Button("Find…") {
                withFocusedWindow { store, window in
                    if window.isSettingsPresented {
                        window.focusSettingsSearch()
                    } else {
                        store.showFindBar(in: window)
                    }
                }
            }
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
            // mnemonic; Cmd+Ctrl+P is Picture-in-Picture (the View menu).
            Button(
                (windowState?.isPresentationMode ?? false)
                    ? "Exit Presentation Mode" : "Enter Presentation Mode"
            ) {
                windowState?.isPresentationMode.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(windowState == nil)
        }

        // Full-page zoom (non-spec: user-requested). Cmd+= / Cmd+- / Cmd+0, the
        // same bindings as every browser. Applied via WKWebView.pageZoom (the
        // layout/viewport level, not text size) and persisted globally.
        //
        // A `CommandMenu("View")` would create a *second* "View" menu — the
        // system already ships one (Enter Full Screen, …). Appending to the
        // `toolbar` group lands these items in the existing View menu, the
        // same slot the sidebar/presentation-mode items already use.
        CommandGroup(after: .toolbar) {
            Button {
                zoom("Zoom", icon: "plus.magnifyingglass", { $0.zoomIn() })
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut("=", modifiers: .command)
            Button {
                zoom("Zoom", icon: "minus.magnifyingglass", { $0.zoomOut() })
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            Button {
                zoom("Zoom", icon: "1.magnifyingglass", { $0.zoomReset() })
            } label: {
                Label("Actual Size", systemImage: "1.magnifyingglass")
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()

            // App-driven Picture-in-Picture (non-spec: user-requested). Drives
            // the focused pane's video into a floating window via WebKit's
            // legacy presentation-mode API — the only PiP path a native-macOS
            // WKWebView exposes (the standard `requestPictureInPicture()` API
            // reports unsupported in embedded web views). The label flips
            // between Enter/Exit from the engine's cache, so it stays honest
            // when PiP is started or ended elsewhere. Cmd+Ctrl+P, the binding
            // Orion — the browser this feature mirrors — uses.
            Button {
                withFocusedWindow { store, window in
                    Task { await store.togglePictureInPicture(in: window) }
                }
            } label: {
                let isActive = windowState.flatMap { store?.isPictureInPictureActive(in: $0) } ?? false
                Label(
                    isActive ? "Exit Picture in Picture" : "Enter Picture in Picture",
                    systemImage: isActive ? "pip.exit" : "pip"
                )
            }
            .keyboardShortcut("p", modifiers: [.command, .control])
            .disabled(windowState == nil)
        }

        // Developer features (non-spec: user-requested). The Web Inspector and
        // the DRM Diagnostics panel both only exist when Developer Mode is on —
        // that is the release-build gate. When it is off the items are disabled,
        // and the store no-ops anyway.
        CommandMenu("Develop") {
            Toggle("Developer Mode", isOn: developerModeBinding)
            Divider()
            Button("Show Web Inspector") {
                withFocusedWindow { store, window in
                    store.showWebInspector(in: window)
                }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(store?.developerMode != true || windowState == nil)
            Button("DRM Diagnostics…") {
                withFocusedWindow { store, window in
                    store.showDRMDiagnostics(in: window)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(store?.developerMode != true || windowState == nil)
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
