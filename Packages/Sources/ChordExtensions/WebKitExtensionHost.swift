import ChordCore
import ChordEngine
import Foundation
import WebKit

/// Allows an extension's docked panel page to ask for its own camera,
/// microphone or screen. The Mac still shows the picker for `getDisplayMedia`,
/// and only while Chord's capture call is in flight.
private final class ExtensionPanelMediaDelegate: NSObject, WKUIDelegate {
    let capture: ExtensionCapture

    init(capture: ExtensionCapture) {
        self.capture = capture
        super.init()
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        .grant
    }

    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func displayCapture(
        _ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
        systemAudio: Bool, decisionHandler: @escaping (Int) -> Void
    ) {
        decisionHandler(capture.displayDecision(for: webView))
    }
}

/// The per-Space `WKWebExtensionController` registry (M7, ADR 011).
///
/// One controller per Space, each with its own persistent on-disk storage keyed
/// by the Space's `dataStoreID` and its own website data store — the same
/// isolation model Spaces already give cookies and localStorage, extended to
/// extension storage, permissions, and (once contexts are loaded, 7.3+)
/// background workers. A background service worker therefore costs one process
/// *per Space it is enabled in*; §6.6 asks that per-Space cost be surfaced in
/// the UI, which a later phase does.
///
/// This is one of only two WebKit importers in the app; nothing WebKit-shaped
/// leaves it. The engine attaches a controller via the opaque
/// `ExtensionControllerHandle`; everything else the app sees is on
/// `ExtensionHost`, which is WebKit-free.
@MainActor
public final class WebKitExtensionHost: NSObject, ExtensionHost {
    /// The sidebar's manage button, used as a popup anchor when an
    /// extension's own button has not registered one (it was rebuilt while
    /// the action list grew).
    public static let managerAnchorSlug = "__chord.manager"
    // `private(set)` rather than `private` so the package's own tests can reach
    // the controllers through `@testable`; the handle's controller is internal
    // to the engine and cannot be read from here.
    private(set) var controllers: [UUID: WKWebExtensionController] = [:]
    /// The website data store backing each Space's controller, kept so stale
    /// extension service-worker registrations can be cleared without creating
    /// a second store for a private Space.
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]

    private struct Loaded {
        let context: WKWebExtensionContext
        let descriptor: LoadedExtension
        let installed: InstalledExtension
        let wasLoadedBefore: Bool
    }
    /// Loaded contexts, keyed by Space then by extension slug.
    private var loadedContexts: [UUID: [String: Loaded]] = [:]
    /// Docked side-panel pages, keyed "space|slug". Kept while the panel is
    /// open; closing releases them.
    private var sidePanelViews: [String: WKWebView] = [:]
    private var sidePanelDelegates: [String: ExtensionPanelMediaDelegate] = [:]

    /// Context error observations, keyed by "space|slug".
    private var errorWatchers: [String: NSObjectProtocol] = [:]
    /// Last automatic revival, so a worker that can never start is not put
    /// through an unload/load loop once a second.
    private var revived: [String: Date] = [:]
    /// Per-(Space, extension) worker generations and background lifetimes
    /// (899/worker recovery). Shared so content controllers built by the
    /// engine can carry its bridge too.
    let workerRecovery = ExtensionWorkerRecovery.shared
    /// Screen recording for extension pages: the `chordCapture` channel,
    /// one-use stream ids and WebKit's display-capture answer.
    let capture = ExtensionCapture()
    /// Spaces whose stale service-worker registrations have been cleared this
    /// launch. The check is per-space and cheap after the first extension.
    private var clearedWorkers: Set<UUID> = []
    /// (Space, Chrome id) pairs loaded at least once this run, for the shim's
    /// `onInstalled` reason: WebKit says "install" again on every reload.
    private var loadedOnce: Set<String> = []
    /// `windows.create({ type: "popup" })` windows of extensions' own pages,
    /// per Space. Each has a window id of its own (see ExtensionPopoutWindow).
    private var popouts: [UUID: [ExtensionPopoutWindow]] = [:]

    /// Store-side data APIs for the full Chrome shim (M9). WebKit-free at this
    /// seam: the host passes only an id and a Space.
    public weak var shimData: (any ExtensionShimData)?

    /// Fired on the main actor when an extension updates its action (7.5a).
    public var onActionsChanged: (@MainActor () -> Void)?

    /// Weakly-held anchor views for popovers (7.5b), keyed by Space then slug.
    /// Weak so a torn-down sidebar button auto-clears without an unregister call.
    private final class WeakView { weak var view: NSView?; init(_ v: NSView?) { view = v } }
    private var actionAnchors: [UUID: [String: WeakView]] = [:]

    /// Fired when a popup opens or closes, with the window it is anchored in, so
    /// the UI can pin that window's revealed sidebar open while it is up. See
    /// `ExtensionHost.onPopupVisibilityChanged` for why this exists.
    public var onPopupVisibilityChanged: (@MainActor (AnyObject?, Bool) -> Void)?

    /// The popover currently on screen, so `popoverDidClose` can be matched to
    /// the window that was reported when it opened. Held weakly: AppKit owns it,
    /// and a closed popover must not be kept alive by this bookkeeping.
    private weak var visiblePopover: NSPopover?
    private weak var visiblePopoverWindow: NSWindow?

    // MARK: - Permissions (7.5c)

    /// Persists grants and reads them back at load. Injected by `AppEnvironment`;
    /// `nil` leaves grants live-only (they still work for the session, just are
    /// not re-applied next launch).
    public var permissionsRepository: (any GrantedPermissionsRepository)?

    /// Fired on the main actor when an extension asks for a permission (7.5c).
    public var onPermissionRequest: (@MainActor (PermissionRequest) -> Void)?

    /// Fired on the main actor after the user grants an extension host access on
    /// enable, so the app can reload the affected Space's tabs — content scripts
    /// only inject on a fresh load, so an already-open page needs a reload before
    /// a just-enabled extension takes effect on it.
    public var onHostAccessChanged: (@MainActor (_ spaceID: UUID) -> Void)?

    /// A prompt awaiting the user's decision: how to answer WebKit, and what to
    /// persist if the answer is "allow".
    private struct PendingPermission {
        let spaceID: UUID
        let slug: String
        let kind: GrantedPermissionKind
        let values: [String]
        /// Calls the WebKit completion handler — the full set on allow, empty on
        /// deny.
        let respond: (_ allow: Bool) -> Void
    }
    private var pendingPermissions: [UUID: PendingPermission] = [:]
    /// Permission requests for APIs Chord answers itself (history, bookmarks,
    /// downloads, …). They use the same UI sheet but do not go to WebKit's
    /// permission table.
    private var pendingShimPermissions: [UUID: (Bool) -> Void] = [:]

    // MARK: - Tab/window model (7.3b)

    /// Injected by `AppEnvironment`. Both are WebKit-free at the seam: the model
    /// is `TabStore`, the provider is the engine forwarded as an existential.
    public weak var tabModel: (any ExtensionTabModel)?
    public weak var paneWebViewProvider: (any PaneWebViewProviding)?

    /// One window adapter per Space and one tab adapter per (Space, tab), cached
    /// so WebKit sees a stable object identity for each.
    private var windowAdapters: [UUID: ExtensionWindowAdapter] = [:]
    private var tabAdapters: [UUID: [UUID: ExtensionTabAdapter]] = [:]
    /// Reverse map for delegate callbacks, which hand back a controller.
    private var controllerSpace: [ObjectIdentifier: UUID] = [:]
    /// Space metadata needed after `prepare` (e.g. private-ness).
    private var spaces: [UUID: Space] = [:]

    public override init() {
        // Extension pages must use Chrome's origin, not WebKit's private one:
        // `chrome-extension://<id>/` is what native-messaging hosts allow and
        // what servers and extension code recognise. Registering the scheme
        // once is enough for every controller in the process.
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        super.init()
        capture.context = { [weak self] identifier in
            self?.context(identifier: identifier)
        }
        capture.bringForward = { [weak self] web in
            await self?.bringForward(web) ?? false
        }
    }

    public var preparedSpaceIDs: Set<UUID> { Set(controllers.keys) }

    @discardableResult
    public func prepare(_ space: Space) -> ExtensionControllerHandle {
        spaces[space.id] = space
        if let existing = controllers[space.id] {
            return controllerHandle(existing, for: space.id)
        }

        let controller = WKWebExtensionController(configuration: makeConfiguration(for: space))
        controller.delegate = self
        controllers[space.id] = controller
        controllerSpace[ObjectIdentifier(controller)] = space.id
        Log.extensions.debug(
            "prepared extension controller for space \(space.id)"
        )
        return controllerHandle(controller, for: space.id)
    }

    /// The handle the engine attaches to every page's configuration. The
    /// worker-recovery bridge travels with it so each new content controller
    /// gains the extension's isolated-world handler (899/worker recovery).
    private func controllerHandle(
        _ controller: WKWebExtensionController, for spaceID: UUID
    ) -> ExtensionControllerHandle {
        ExtensionControllerHandle(
            controller,
            attachWorkerRecovery: { [workerRecovery] contentController in
                workerRecovery.attach(spaceID: spaceID, controller: contentController)
            },
            attachCapture: { [capture] contentController in
                capture.attach(contentController)
            },
            captureDisplayDecision: { [capture] web in
                capture.displayDecision(for: web)
            }
        )
    }

    // MARK: - Adapter cache (7.3b)

    func windowAdapter(forSpace spaceID: UUID) -> ExtensionWindowAdapter {
        if let existing = windowAdapters[spaceID] { return existing }
        let adapter = ExtensionWindowAdapter(spaceID: spaceID, host: self)
        windowAdapters[spaceID] = adapter
        return adapter
    }

    func tabAdapter(for tabID: UUID, inSpace spaceID: UUID) -> ExtensionTabAdapter {
        if let existing = tabAdapters[spaceID]?[tabID] { return existing }
        let adapter = ExtensionTabAdapter(tabID: tabID, spaceID: spaceID, host: self)
        tabAdapters[spaceID, default: [:]][tabID] = adapter
        return adapter
    }

    /// The app window showing a Space, for the frame its extensions see: one
    /// its toolbar buttons sit in, else the main window.
    func appWindow(forSpace spaceID: UUID) -> NSWindow? {
        actionAnchors[spaceID]?.values.lazy.compactMap { $0.view?.window }.first
            ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    func isSpacePrivate(_ spaceID: UUID) -> Bool {
        spaces[spaceID]?.isPrivate ?? false
    }

    // MARK: - Tab lifecycle (7.3b) — called by the Store

    public func extensionTabDidOpen(_ tabID: UUID, inSpace spaceID: UUID) {
        guard let controller = controllers[spaceID] else { return }
        controller.didOpenTab(tabAdapter(for: tabID, inSpace: spaceID))
    }

    public func extensionTabDidActivate(
        _ tabID: UUID, previous previousTabID: UUID?, inSpace spaceID: UUID
    ) {
        guard let controller = controllers[spaceID] else { return }
        let previous = previousTabID.map { tabAdapter(for: $0, inSpace: spaceID) }
        controller.didActivateTab(
            tabAdapter(for: tabID, inSpace: spaceID), previousActiveTab: previous
        )
    }

    public func extensionTabDidClose(_ tabID: UUID, inSpace spaceID: UUID) {
        guard let controller = controllers[spaceID] else {
            tabAdapters[spaceID]?[tabID] = nil
            return
        }
        let adapter = tabAdapter(for: tabID, inSpace: spaceID)
        controller.didCloseTab(adapter, windowIsClosing: false)
        tabAdapters[spaceID]?[tabID] = nil
    }

    public func extensionTabDidMove(
        _ tabID: UUID, from oldIndex: Int, inSpace spaceID: UUID
    ) {
        guard let controller = controllers[spaceID] else { return }
        controller.didMoveTab(
            tabAdapter(for: tabID, inSpace: spaceID),
            from: oldIndex,
            in: windowAdapter(forSpace: spaceID)
        )
    }

    /// `chrome.tabs.move`: the shim sends the tab's place and the requested
    /// flat index. The Store clamps it into Chord's section order.
    func moveTab(for place: Any?, to index: Int, spaceID: UUID) {
        guard let tab = shimTabs(place, spaceID: spaceID).first else { return }
        tabModel?.extensionMoveTab(tab.id, to: index, inSpace: spaceID)
    }

    // MARK: - Loading (7.3)

    /// Re-prepares the shim with the worker generation this load starts at, so
    /// the new worker doesn't believe it is generation 0 while recovery says
    /// otherwise. A no-op when the stamp already matches. Off the main actor:
    /// a large bundle (Grammarly) takes ~450 ms to rewrite. Best-effort, as in
    /// Search: a failure leaves the old shim, which still works.
    ///
    /// The prepared folder is shared by every Space but generations are per
    /// Space, so the last load wins the stamp. That is safe: the shim takes the
    /// max of its stamped generation and each one recovery reports back.
    private func restampShim(of installed: InstalledExtension, in space: Space) async {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: installed.resourceURL.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else { return }
        let generation = workerRecovery.generation(
            for: ExtensionWorkerRecovery.Key(spaceID: space.id, slug: installed.slug)
        )
        let folder = installed.resourceURL
        try? await Task.detached(priority: .userInitiated) {
            try ExtensionShims.prepare(folder, workerGeneration: generation)
        }.value
    }

    @discardableResult
    public func load(_ installed: InstalledExtension, in space: Space) async throws
        -> LoadedExtension
    {
        // Loading a slug that is already live is a reload: unload the old
        // context first, and tell its pages their ports belong to a retired
        // context (899/worker recovery). Without this, WebKit can end up with
        // two contexts for one origin.
        if let previous = loadedContexts[space.id]?[installed.slug] {
            closePopouts(of: previous.context, in: space.id)
            try? controllers[space.id]?.unload(previous.context)
            loadedContexts[space.id]?[installed.slug] = nil
            ExtensionOffscreen.close(
                identifier: previous.installed.identifier, spaceID: space.id
            )
            capture.purge(previous.installed.identifier)
            ExtensionSocket.endConnections(of: previous.context)
            ExtensionNative.stopOrphans()
            let key = ExtensionWorkerRecovery.Key(
                spaceID: space.id, slug: installed.slug
            )
            if let watcher = errorWatchers.removeValue(
                forKey: watchKey(spaceID: space.id, slug: installed.slug)
            ) {
                NotificationCenter.default.removeObserver(watcher)
            }
            workerRecovery.restarted(key, replacingContext: true)
            workerRecovery.unregister(key)
            workersChanged(in: space.id)
        }

        await restampShim(of: installed, in: space)

        let webExtension: WKWebExtension
        do {
            webExtension = try await WKWebExtension(resourceBaseURL: installed.resourceURL)
        } catch {
            throw ExtensionLoadError.unreadableBundle(error)
        }

        // MV3 only (4.7). WebKit will happily load MV2; this is our policy,
        // applied at the first point the manifest has actually been parsed.
        guard webExtension.manifestVersion >= 3 else {
            throw ExtensionLoadError.unsupportedManifestVersion(webExtension.manifestVersion)
        }

        prepare(space)  // ensures the Space's controller exists and is cached
        let controller = controllers[space.id]!
        await clearStaleWorkers(for: space)
        let context = WKWebExtensionContext(for: webExtension)
        // Chrome's id, not the human-readable slug: it is the stable
        // `chrome-extension://<id>/` origin, the native-messaging origin, and
        // the key Chrome Web Store updates use. The controller is already
        // per-Space, so the same id in another Space still has separate
        // storage and a separate worker.
        context.uniqueIdentifier = installed.identifier
        guard let baseURL = URL(string: "chrome-extension://\(installed.identifier)/")
        else { throw ExtensionShimError.invalidIdentifier }
        context.baseURL = baseURL
        // Its worker and pages show in Safari's Develop menu, as in Search.
        context.isInspectable = true
        // Pages in engine tabs get the capture channel through the controller
        // handle; pages built from the extension configuration get it from
        // the controller's view configuration (`makeConfiguration`).

        // Re-apply permissions the user granted in a previous session (7.5c),
        // before the extension starts, so content scripts and host access work
        // without re-prompting. Best-effort: a repo read failure just means the
        // user may be prompted again.
        if let grants = try? await permissionsRepository?.granted(
            slug: installed.slug, spaceID: space.id
        ) {
            reapply(grants, to: context)
        }

        // A real browser grants an MV3 extension's declared *API* permissions
        // (tabs, storage, scripting, declarativeNetRequest, webNavigation, …) at
        // install without a prompt — only host access is gated behind consent.
        // WebKit leaves them in a "requested" state, and a background service
        // worker that cannot use its declared APIs fails to start: that is the
        // "the menu had trouble loading" symptom seen with AdBlock. Grant the
        // declared API permissions up front so the background actually runs.
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        // WebKit otherwise refuses `runtime.connectNative` even though the
        // manifest (and Chord's shim) asks for it. Chrome grants this at
        // install; the per-host allow-list is enforced in ExtensionNative.
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)

        // Before load: WebKit can create the background synchronously inside
        // it, and the callback must already have somewhere to land.
        let recoveryUndo = workerRecovery.register(
            context, spaceID: space.id, slug: installed.slug
        )
        do {
            try controller.load(context)
        } catch {
            recoveryUndo()
            throw ExtensionLoadError.controllerRejected(error)
        }

        // Parse/load errors surface here; log them so a broken bundle is
        // diagnosable rather than silently inert.
        if !context.errors.isEmpty {
            Log.extensions.error(
                "extension \(installed.slug) reported errors: \(String(describing: context.errors))"
            )
        }

        let loadedKey = "\(space.id)|\(installed.identifier)"
        let wasLoadedBefore = loadedOnce.contains(loadedKey)
        let descriptor = LoadedExtension(
            slug: installed.slug,
            identifier: installed.identifier,
            spaceID: space.id,
            displayName: webExtension.displayName,
            manifestVersion: webExtension.manifestVersion,
            hasBackgroundContent: webExtension.hasBackgroundContent,
            hasPersistentBackgroundContent: webExtension.hasPersistentBackgroundContent
        )
        loadedContexts[space.id, default: [:]][installed.slug] = Loaded(
            context: context, descriptor: descriptor, installed: installed,
            wasLoadedBefore: wasLoadedBefore
        )
        loadedOnce.insert(loadedKey)
        watchErrors(context, spaceID: space.id, slug: installed.slug)
        Log.extensions.notice(
            "loaded extension \(installed.slug) as \(installed.identifier) in space \(space.id)"
        )
        // Tell the UI to re-read `actions(in:)`. WebKit's `didUpdate action:`
        // does not fire for an extension's statically-declared default action on
        // first load, so without this the sidebar header — rendered before
        // restore finished — never refreshes and its toolbar buttons stay hidden
        // until an unrelated re-render (e.g. collapsing the sidebar). See 7.5a.
        onActionsChanged?()
        return descriptor
    }

    public func unload(slug: String, in space: Space) throws {
        guard let loaded = loadedContexts[space.id]?[slug] else { return }
        let key = watchKey(spaceID: space.id, slug: slug)
        if let watcher = errorWatchers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(watcher)
        }
        revived[key] = nil
        closePopouts(of: loaded.context, in: space.id)
        var unloadError: Error?
        if let controller = controllers[space.id] {
            do {
                try controller.unload(loaded.context)
            } catch {
                unloadError = error
            }
        }
        loadedContexts[space.id]?[slug] = nil
        // Every port the extension held belonged to this context. Raise the
        // generation so its pages learn to reconnect to whatever replaces it,
        // and detach the content-script bridge (899/worker recovery).
        let recoveryKey = ExtensionWorkerRecovery.Key(
            spaceID: space.id, slug: slug
        )
        workerRecovery.restarted(recoveryKey, replacingContext: true)
        workerRecovery.unregister(recoveryKey)
        workersChanged(in: space.id)
        ExtensionOffscreen.close(identifier: loaded.installed.identifier, spaceID: space.id)
        capture.purge(loaded.installed.identifier)
        closeSidePanel(slug: slug, in: space)
        ExtensionSocket.endConnections(of: loaded.context)
        ExtensionNative.stopOrphans()
        Log.extensions.notice(
            "unloaded extension \(slug) in space \(space.id)"
        )
        // Same reason as `load`: refresh the header so the removed button clears.
        onActionsChanged?()
        if let unloadError {
            throw ExtensionLoadError.controllerRejected(unloadError)
        }
    }

    public func spaceDidClose(_ space: Space) async {
        for slug in (loadedContexts[space.id] ?? [:]).keys.sorted() {
            try? unload(slug: slug, in: space)
        }
        for popout in popouts[space.id] ?? [] { popout.close() }
        for (id, pending) in pendingPermissions where pending.spaceID == space.id {
            resolvePermission(id: id, allow: false)
        }
        if let controller = controllers[space.id] {
            controllerSpace[ObjectIdentifier(controller)] = nil
        }
        loadedContexts[space.id] = nil
        tabAdapters[space.id] = nil
        windowAdapters[space.id] = nil
        actionAnchors[space.id] = nil
        popouts[space.id] = nil
        clearedWorkers.remove(space.id)
        loadedOnce = loadedOnce.filter { !$0.hasPrefix("\(space.id)|") }
        spaces[space.id] = nil
        dataStores[space.id] = nil
        // Gone for good, so what it remembered across launches goes too.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.workersKey(space.id))
        let settings = ExtensionSettings.key(identifier: "", spaceID: space.id)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(settings) {
            defaults.removeObject(forKey: key)
        }
        // Last, after everything that unloads through it.
        controllers[space.id] = nil
        Log.extensions.notice("closed extension space \(space.id)")
    }

    public func loadedExtensions(in space: Space) -> [LoadedExtension] {
        (loadedContexts[space.id] ?? [:]).values
            .map(\.descriptor)
            .sorted { $0.slug < $1.slug }
    }

    /// The live context for an extension, for tests and diagnostics. Internal:
    /// no WK* type crosses the package boundary.
    func context(forSlug slug: String, in space: Space) -> WKWebExtensionContext? {
        loadedContexts[space.id]?[slug]?.context
    }

    /// A loaded context by its Chrome id, for the capture channel's sender
    /// check. Few extensions load, so a linear scan is enough.
    func context(identifier: String) -> WKWebExtensionContext? {
        for bySlug in loadedContexts.values {
            for loaded in bySlug.values
            where loaded.context.uniqueIdentifier.caseInsensitiveCompare(identifier)
                == .orderedSame {
                return loaded.context
            }
        }
        return nil
    }

    /// Selects the tab an extension's page is in and raises its window. WebKit
    /// refuses to start a recording in a page that is not visible; a popup or
    /// a docked panel is already on screen, but an options page may sit in a
    /// background tab. Not in a test run, where nothing is shown.
    private func bringForward(_ web: WKWebView) async -> Bool {
        if web.window?.isVisible == true,
           (try? await web.evaluateJavaScript("document.visibilityState")) as? String
            == "visible" {
            return true
        }
        if let provider = paneWebViewProvider,
           let paneID = provider.paneID(for: web),
           let model = tabModel {
            for spaceID in spaces.keys {
                if let tab = model.extensionTabs(inSpace: spaceID)
                    .first(where: { $0.focusedPaneID == paneID }) {
                    model.extensionActivateTab(tab.id)
                    break
                }
            }
        }
        web.window?.makeKeyAndOrderFront(nil)
        for _ in 0..<20 {
            if web.window?.isVisible == true,
               web.window?.occlusionState.contains(.visible) == true,
               (try? await web.evaluateJavaScript("document.visibilityState")) as? String
                == "visible" {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    // MARK: - Toolbar actions (7.5a)

    public func actions(in space: Space) -> [ExtensionActionSnapshot] {
        let active = tabModel?.extensionActiveTab(inSpace: space.id)
        let adapter = active.map { tabAdapter(for: $0.id, inSpace: space.id) }
        let built: [ExtensionActionSnapshot] = (loadedContexts[space.id] ?? [:])
            .sorted { $0.key < $1.key }
            .compactMap { slug, loaded in
                // Some extensions (Bitwarden) publish an action only for the
                // tab in front; the header button represents that tab. Others
                // (Loom, Awesome Screenshot) have no per-tab action yet, so
                // WebKit answers nil — fall back to the default action rather
                // than hiding the button entirely.
                guard let action = loaded.context.action(for: adapter)
                        ?? loaded.context.action(for: nil)
                else { return nil }
                return snapshot(of: action, slug: slug, spaceID: space.id)
            }
        return built
    }

    private func snapshot(
        of action: WKWebExtension.Action, slug: String, spaceID: UUID
    ) -> ExtensionActionSnapshot {
        ExtensionActionSnapshot(
            slug: slug,
            spaceID: spaceID,
            label: action.label,
            badgeText: action.badgeText,
            presentsPopup: action.presentsPopup,
            enabled: action.isEnabled,
            icon: Self.pngData(from: action.icon(for: CGSize(width: 32, height: 32)))
        )
    }

    /// Renders an `NSImage` to PNG so no AppKit image type crosses into UI.
    private static func pngData(from image: NSImage?) -> Data? {
        guard let image,
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Popover (7.5b)

    public func registerActionAnchor(_ view: NSView?, forSlug slug: String, in space: Space) {
        actionAnchors[space.id, default: [:]][slug] = WeakView(view)
    }

    public func presentAction(slug: String, in space: Space) {
        guard let loaded = loadedContexts[space.id]?[slug] else { return }
        // A press on the button of an extension whose popup is up closes it;
        // the same click must not reopen it.
        if ExtensionPopup.shared.closes(loaded.context.uniqueIdentifier) { return }
        // Perform the action for the Space's active tab if there is one, so a
        // popup opens against the page the user is actually reading and the tab
        // is marked as having a user gesture. A popup is opened here, straight
        // away, as in Search: left to WebKit, some extensions (Loom, Awesome
        // Screenshot) publish no per-tab action and `performAction` quietly
        // does nothing.
        let activeTab = tabModel?.extensionActiveTab(inSpace: space.id)
        let adapter = activeTab.map { tabAdapter(for: $0.id, inSpace: space.id) }
        if let adapter { loaded.context.userGesturePerformed(in: adapter) }
        let action = loaded.context.action(for: adapter)
            ?? loaded.context.action(for: nil)
        if action?.presentsPopup == true,
           let url = action?.popupWebView?.url ?? popupURL(for: loaded.context) {
            let own = actionAnchors[space.id]?[slug]?.view
            let anchor = (own?.window != nil ? own : nil)
                ?? actionAnchors[space.id]?[Self.managerAnchorSlug]?.view
            showPopup(url, for: loaded.context, from: anchor, spaceID: space.id)
            return
        }
        loaded.context.performAction(for: adapter)
    }

    // MARK: - Permissions (7.5c)

    public func resolvePermission(id: UUID, allow: Bool) {
        if let shim = pendingShimPermissions.removeValue(forKey: id) {
            shim(allow)
            return
        }
        guard let pending = pendingPermissions.removeValue(forKey: id) else { return }
        pending.respond(allow)
        guard allow else { return }
        let records = pending.values.map {
            GrantedPermissionRecord(
                spaceID: pending.spaceID, slug: pending.slug, kind: pending.kind, value: $0
            )
        }
        // Fire-and-forget persistence; the live grant already took effect via
        // `respond`. A weak repo capture keeps the host from outliving a write.
        if let repo = permissionsRepository {
            Task { try? await repo.grant(records) }
        }
    }

    // MARK: - Host access (7.5d)

    public func hasAllHostsAccess(slug: String, in space: Space) -> Bool {
        loadedContexts[space.id]?[slug]?.context.hasAccessToAllHosts ?? false
    }

    public func promptForHostAccess(slug: String, in space: Space) {
        guard let loaded = loadedContexts[space.id]?[slug] else { return }
        let context = loaded.context
        // What the manifest asks for (host_permissions + content-script matches).
        // Nothing to do if it wants no hosts, or already has what it needs.
        let patterns = Array(context.webExtension.allRequestedMatchPatterns)
        guard !patterns.isEmpty, !context.hasAccessToAllHosts else { return }

        enqueuePermission(
            spaceID: space.id, slug: slug, kind: .matchPattern,
            values: patterns.map(\.string), displayName: loaded.descriptor.displayName
        ) { [weak self] allow in
            guard let self, allow else { return }
            for pattern in patterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            if let repo = self.permissionsRepository {
                let records = patterns.map {
                    GrantedPermissionRecord(
                        spaceID: space.id, slug: slug, kind: .matchPattern, value: $0.string
                    )
                }
                Task { try? await repo.grant(records) }
            }
            // Reload so content scripts inject into the already-open page.
            self.onHostAccessChanged?(space.id)
        }
    }

    public func setAllHostsAccess(_ granted: Bool, slug: String, in space: Space) {
        guard let context = loadedContexts[space.id]?[slug]?.context else { return }
        // WebKit does not prompt for a *required* `host_permissions` extension
        // (verified live, 7.5c), so this is the direct "grant host access"
        // affordance — the analogue of Safari's per-site toolbar menu, for all
        // sites at once.
        let pattern = WKWebExtension.MatchPattern.allHostsAndSchemes()
        context.setPermissionStatus(granted ? .grantedExplicitly : .deniedExplicitly, for: pattern)
        guard let repo = permissionsRepository else { return }
        if granted {
            let record = GrantedPermissionRecord(
                spaceID: space.id, slug: slug, kind: .matchPattern, value: pattern.string
            )
            Task { try? await repo.grant([record]) }
        } else {
            // Turning access off drops the extension's persisted grants, so it is
            // not re-granted on the next launch. A denial is not persisted.
            Task { try? await repo.revokeAll(slug: slug, spaceID: space.id) }
        }
    }

    /// Re-applies persisted grants to a freshly created context (7.5c). Only
    /// `.grantedExplicitly` is set here — Denied/Unknown are the WebKit defaults
    /// and we never persist a denial.
    private func reapply(_ grants: [GrantedPermissionRecord], to context: WKWebExtensionContext) {
        for grant in grants {
            switch grant.kind {
            case .permission:
                context.setPermissionStatus(
                    .grantedExplicitly, for: WKWebExtension.Permission(rawValue: grant.value)
                )
            case .url:
                guard let url = URL(string: grant.value) else { continue }
                context.setPermissionStatus(.grantedExplicitly, for: url)
            case .matchPattern:
                guard let pattern = try? WKWebExtension.MatchPattern(string: grant.value)
                else { continue }
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
        }
    }

    /// Records a prompt and either surfaces it to the UI or, if no observer is
    /// wired, denies it (so the completion handler is never dropped).
    private func enqueuePermission(
        spaceID: UUID,
        slug: String,
        kind: GrantedPermissionKind,
        values: [String],
        displayName: String?,
        respond: @escaping (_ allow: Bool) -> Void
    ) {
        let id = UUID()
        pendingPermissions[id] = PendingPermission(
            spaceID: spaceID, slug: slug, kind: kind, values: values, respond: respond
        )
        guard let onPermissionRequest else {
            resolvePermission(id: id, allow: false)
            return
        }
        onPermissionRequest(
            PermissionRequest(
                id: id, slug: slug, spaceID: spaceID, kind: kind,
                items: values, displayName: displayName
            )
        )
    }

    /// Finds the (Space, slug) a context belongs to. Few extensions load, so a
    /// linear scan is cheaper than maintaining a reverse map.
    private func locate(_ context: WKWebExtensionContext) -> (spaceID: UUID, slug: String)? {
        for (spaceID, bySlug) in loadedContexts {
            for (slug, loaded) in bySlug where loaded.context === context {
                return (spaceID, slug)
            }
        }
        return nil
    }


    // MARK: - Shim permissions and worker

    /// Holds `chrome.runtime.connect` observers open until the extension's
    /// background is replaced (899/worker recovery). The shim calls this as
    /// `background.observe`; `nil` means the extension is no longer loaded.
    func observeWorker(
        _ context: WKWebExtensionContext, generation: Int, token: String
    ) async -> Int? {
        guard let (spaceID, slug) = locate(context) else { return nil }
        return await workerRecovery.observe(
            ExtensionWorkerRecovery.Key(spaceID: spaceID, slug: slug),
            generation: generation, token: token
        )
    }

    func cancelWorkerObservation(_ context: WKWebExtensionContext, token: String) {
        guard let (spaceID, slug) = locate(context) else { return }
        workerRecovery.cancel(
            ExtensionWorkerRecovery.Key(spaceID: spaceID, slug: slug), token: token
        )
    }

    private func shimGrantKey(_ context: WKWebExtensionContext) -> String {
        "chord.extensions.shim.\(context.uniqueIdentifier)"
    }

    /// Permissions the user granted to the Search-answered side of the shim.
    func shimGranted(_ context: WKWebExtensionContext) -> [String] {
        UserDefaults.standard.stringArray(forKey: shimGrantKey(context)) ?? []
    }

    /// Ask through the existing permission sheet, then remember the grant.
    func requestShimPermissions(
        _ names: [String], context: WKWebExtensionContext
    ) async -> Bool {
        let wanted = Array(Set(names)).sorted()
        guard !wanted.isEmpty else { return true }
        let already = Set(shimGranted(context))
        let missing = wanted.filter { !already.contains($0) }
        guard !missing.isEmpty else { return true }
        guard let (spaceID, slug) = locate(context) else { return false }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            pendingShimPermissions[id] = { allow in
                if allow {
                    let merged = Array(Set(self.shimGranted(context) + missing)).sorted()
                    UserDefaults.standard.set(merged, forKey: self.shimGrantKey(context))
                }
                continuation.resume(returning: allow)
            }
            let request = PermissionRequest(
                id: id, slug: slug, spaceID: spaceID, kind: .permission,
                items: missing, displayName: context.webExtension.displayName
            )
            guard let onPermissionRequest else {
                pendingShimPermissions.removeValue(forKey: id)
                continuation.resume(returning: false)
                return
            }
            onPermissionRequest(request)
        }
    }

    func removeShimPermissions(_ names: [String], context: WKWebExtensionContext) {
        let gone = Set(names)
        let kept = shimGranted(context).filter { !gone.contains($0) }
        if kept.isEmpty {
            UserDefaults.standard.removeObject(forKey: shimGrantKey(context))
        } else {
            UserDefaults.standard.set(kept, forKey: shimGrantKey(context))
        }
    }

    func wakeBackground(_ context: WKWebExtensionContext) async -> Error? {
        guard context.webExtension.hasBackgroundContent else { return nil }
        return await withCheckedContinuation { continuation in
            var finished = false
            let done: (Error?) -> Void = { error in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: error)
            }
            context.loadBackgroundContent { error in
                DispatchQueue.main.async { done(error) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                done(NSError(domain: "Chord", code: 1,
                             userInfo: [NSLocalizedDescriptionKey: "worker did not answer"]))
            }
        }
    }

    func reviveForShim(_ context: WKWebExtensionContext) {
        guard let (spaceID, slug) = locate(context) else { return }
        revive(spaceID: spaceID, slug: slug, context: context)
    }

    // MARK: - Shim data

    /// The prepared package folder for a live context.
    func extensionFolder(for context: WKWebExtensionContext) -> URL? {
        guard let (spaceID, slug) = locate(context),
              let installed = loadedContexts[spaceID]?[slug]?.installed
        else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: installed.resourceURL.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return installed.resourceURL
    }

    func wasLoadedBefore(_ context: WKWebExtensionContext) -> Bool {
        guard let (spaceID, slug) = locate(context),
              let loaded = loadedContexts[spaceID]?[slug]
        else { return false }
        return loaded.wasLoadedBefore
    }

    /// The extension's own execution contexts, for `runtime.getContexts`.
    func runtimeContexts(_ context: WKWebExtensionContext) -> [[String: Any]] {
        var found: [[String: Any]] = []
        let manifest = context.webExtension.manifest
        if context.webExtension.hasBackgroundContent {
            let background = manifest["background"] as? [String: Any] ?? [:]
            let script = background["service_worker"] as? String
                ?? background["page"] as? String
            let url = script.map {
                context.baseURL.appendingPathComponent($0).absoluteString
            } ?? context.baseURL.absoluteString
            found.append([
                "contextType": "BACKGROUND",
                "contextId": "\(context.uniqueIdentifier)-background",
                "tabId": -1, "windowId": -1, "frameId": -1,
                "documentUrl": url,
                "documentOrigin": context.baseURL.absoluteString,
                "incognito": false,
            ])
        }
        if let url = ExtensionOffscreen.url(
            identifier: context.uniqueIdentifier, spaceID: locate(context)?.spaceID ?? UUID()
        ) {
            found.append([
                "contextType": "OFFSCREEN_DOCUMENT",
                "contextId": "\(context.uniqueIdentifier)-offscreen",
                "tabId": -1, "windowId": -1, "frameId": 0,
                "documentUrl": url.absoluteString,
                "documentOrigin": context.baseURL.absoluteString,
                "incognito": false,
            ])
        }
        return found
    }

    /// The extension's own pages that are open, for `clients.matchAll()`.
    func extensionPages(spaceID: UUID, identifier: String) -> [[String: Any]] {
        var pages: [[String: Any]] = []
        for tab in tabModel?.extensionTabs(inSpace: spaceID) ?? [] {
            guard let url = tab.url, url.scheme?.lowercased() == "chrome-extension",
                  url.host?.lowercased() == identifier.lowercased()
            else { continue }
            pages.append([
                "id": tab.id.uuidString, "url": url.absoluteString,
                "visible": tab.isSelected, "focused": tab.isSelected,
            ])
        }
        if let url = ExtensionOffscreen.url(
            identifier: identifier, spaceID: spaceID
        ) {
            pages.append([
                "id": "offscreen", "url": url.absoluteString,
                "visible": false, "focused": false,
            ])
        }
        return pages
    }

    private func shimTabs(_ places: Any?, spaceID: UUID) -> [ExtensionTabSnapshot] {
        let all = tabModel?.extensionTabs(inSpace: spaceID) ?? []
        guard let places = places as? [[String: Any]] else { return all }
        return places.compactMap { place in
            guard let index = place["i"] as? Int, all.indices.contains(index)
            else { return nil }
            return all[index]
        }
    }

    func tabDescriptions(for places: Any?, spaceID: UUID) -> [[String: Any]] {
        shimTabs(places, spaceID: spaceID).map { tab in
            var value: [String: Any] = ["url": tab.url?.absoluteString ?? ""]
            if !tab.title.isEmpty { value["title"] = tab.title }
            if let data = tab.faviconData {
                value["favIconUrl"] = "data:image/png;base64," + data.base64EncodedString()
            }
            return value
        }
    }

    func tabPrivacy(for places: Any?, spaceID: UUID) -> Any {
        let tabs = shimTabs(places, spaceID: spaceID)
        if places is [[String: Any]] { return tabs.map(\.isPrivate) }
        return tabs.contains(where: \.isPrivate)
    }

    /// Chord's folders are shown to Chrome as tab groups. Until the folder
    /// bridge lands, a tab reports "no group" (`-1`), which every extension
    /// understands.
    func tabGroups(for places: Any?, spaceID: UUID) -> [Int] {
        shimTabs(places, spaceID: spaceID).map { $0.groupNumber ?? -1 }
    }

    func activateTab(for place: Any?, spaceID: UUID) {
        guard let tab = shimTabs(place, spaceID: spaceID).first else { return }
        tabModel?.extensionActivateTab(tab.id)
    }

    // MARK: - Worker health

    private func watchKey(spaceID: UUID, slug: String) -> String {
        "\(spaceID.uuidString)|\(slug)"
    }

    /// Clear extension service-worker registrations when what they would run
    /// has changed. WebKit keeps each extension's worker registered from one
    /// launch to the next, with the scripts it fetched then, and may start
    /// that copy rather than what is on disk — a copy from another shim or
    /// another install can leave the worker dead for good, and reinstalling
    /// brings the same copy back (Bitwarden: a popup loading for ever, its
    /// worker silent). WebKit lists no records for extension origins, and
    /// clearing stops running workers, so it is done once per Space per
    /// launch, before its first extension loads, as Search does. Website
    /// workers go with them and register again on the next visit.
    private func clearStaleWorkers(for space: Space) async {
        guard !clearedWorkers.contains(space.id) else { return }
        clearedWorkers.insert(space.id)
        guard !space.isPrivate, let store = dataStores[space.id] else { return }
        let key = Self.workersKey(space.id)
        guard UserDefaults.standard.string(forKey: key) != ExtensionShims.version else {
            return
        }
        // Extension pages kept their data in WebKit's default store before
        // they were given the Space's, so a stale registration can be there.
        for stale in [store, WKWebsiteDataStore.default()] {
            await stale.removeData(
                ofTypes: [WKWebsiteDataTypeServiceWorkerRegistrations],
                modifiedSince: .distantPast
            )
        }
        UserDefaults.standard.set(ExtensionShims.version, forKey: key)
        Log.extensions.notice("cleared extension workers in space \(space.id)")
    }

    public func forgetData(identifier: String, in spaces: [Space]) async {
        for space in spaces {
            loadedOnce.remove("\(space.id)|\(identifier)")
            UserDefaults.standard.removeObject(
                forKey: ExtensionSettings.key(identifier: identifier, spaceID: space.id)
            )
            workersChanged(in: space.id)
            prepare(space)
            guard let controller = controllers[space.id] else { continue }
            if await forgetData(of: identifier, in: controller) {
                Log.extensions.notice("cleared data of \(identifier) in space \(space.id)")
            }
        }
    }

    /// Its chrome.storage, which WebKit keeps by id, and what its pages kept
    /// at chrome-extension://<id>. WebKit lists no website records for that
    /// origin, so the second is cleared from a blank page at that origin,
    /// which only an extension context can host: a stand-in with no worker,
    /// scripts or pages of its own, so nothing of the removed extension runs
    /// again. Ported from Search. Whether all of it was cleared.
    private func forgetData(
        of identifier: String, in controller: WKWebExtensionController
    ) async -> Bool {
        let types = WKWebExtensionController.allExtensionDataTypes
        let records = await controller.dataRecords(ofTypes: types)
            .filter { $0.uniqueIdentifier == identifier }
        if !records.isEmpty { await controller.removeData(ofTypes: types, from: records) }
        guard let base = URL(string: "chrome-extension://\(identifier)/") else { return false }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "chord-forget-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"manifest_version": 3, "name": "Chord", "version": "1"}"#.utf8)
                .write(to: folder.appending(path: "manifest.json"))
            let standIn = WKWebExtensionContext(
                for: try await WKWebExtension(resourceBaseURL: folder)
            )
            standIn.uniqueIdentifier = identifier
            standIn.baseURL = base
            try controller.load(standIn)
            defer { try? controller.unload(standIn) }
            guard let configuration = standIn.webViewConfiguration else { return false }
            let page = BlankExtensionPage(configuration)
            guard await page.load(at: base) else {
                Log.extensions.error("could not open \(identifier) to clear what it kept")
                return false
            }
            _ = try await page.web.callAsyncJavaScript(
                Self.forgetScript, contentWorld: .defaultClient
            )
            return true
        } catch {
            Log.extensions.error(
                "could not clear what \(identifier) kept: \(String(describing: error))"
            )
            return false
        }
    }

    private static let forgetScript = """
        localStorage.clear();
        for (const db of await indexedDB.databases()) {
            await new Promise(done => { const q = indexedDB.deleteDatabase(db.name); q.onsuccess = q.onerror = q.onblocked = done; });
        }
        for (const key of await caches.keys()) await caches.delete(key);
        """

    private static func workersKey(_ spaceID: UUID) -> String {
        "chord.extensions.workers.\(spaceID.uuidString)"
    }

    /// An extension installed again, reloaded or removed: the version alone
    /// doesn't tell, so the next launch clears regardless.
    private func workersChanged(in spaceID: UUID) {
        UserDefaults.standard.removeObject(forKey: Self.workersKey(spaceID))
    }

    // MARK: - Side panel

    func shimSlug(for context: WKWebExtensionContext) -> String? {
        locate(context)?.slug
    }

    /// The docked side panel's page. It is an ordinary extension page with the
    /// extension's own configuration (runtime, storage, cookies), kept alive
    /// while the panel is open. The UI receives an `NSView` so no WebKit type
    /// crosses into ChordUI.
    public func sidePanelView(
        slug: String, url: URL, in space: Space
    ) -> NSView? {
        guard let loaded = loadedContexts[space.id]?[slug],
              let configuration = loaded.context.webViewConfiguration
        else { return nil }
        let key = "\(space.id.uuidString)|\(slug)"
        if let existing = sidePanelViews[key] {
            if existing.url != url { existing.load(URLRequest(url: url)) }
            return existing
        }
        let web = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 380, height: 640),
            configuration: configuration
        )
        web.allowsBackForwardNavigationGestures = true
        let media = ExtensionPanelMediaDelegate(capture: capture)
        web.uiDelegate = media
        sidePanelDelegates[key] = media
        sidePanelViews[key] = web
        web.load(URLRequest(url: url))
        return web
    }

    public func closeSidePanel(slug: String, in space: Space) {
        let key = "\(space.id.uuidString)|\(slug)"
        sidePanelViews[key]?.stopLoading()
        sidePanelViews[key] = nil
        sidePanelDelegates[key] = nil
    }

    // MARK: - Externally connectable

    /// The page-world bootstrap listing every loaded extension that names a
    /// website in `externally_connectable`, or nil when none do. The engine
    /// injects this at document start; a page not listed gets no `chrome`.
    public func externallyConnectableScript() -> String? {
        var manifests: [(id: String, manifest: [String: Any])] = []
        for bySlug in loadedContexts.values {
            for loaded in bySlug.values {
                manifests.append((
                    loaded.installed.identifier,
                    loaded.context.webExtension.manifest
                ))
            }
        }
        return ExtensionExternal.script(
            for: ExtensionExternal.listings(from: manifests)
        )
    }

    // MARK: - Worker lifecycle (899/worker recovery)

    /// WebKit calls this before every background web view it creates,
    /// including one woken inside a context that already ran (idle exit,
    /// crash retry). Undocumented but long-lived — the reference browser has
    /// relied on it since WebKit 26, and it is the only signal that
    /// distinguishes "the same worker restarted" from "this port is stale".
    @objc(_webExtensionController:didCreateBackgroundWebView:forExtensionContext:)
    func createdBackground(
        _ controller: WKWebExtensionController,
        webView: WKWebView,
        context: WKWebExtensionContext
    ) {
        workerRecovery.created(webView, in: context)
    }

    /// WebKit records a background worker that failed to start on the context
    /// and then never tries again. Take the same context up afresh once, but
    /// not more than once a minute for one extension.
    private func watchErrors(
        _ context: WKWebExtensionContext, spaceID: UUID, slug: String
    ) {
        let key = watchKey(spaceID: spaceID, slug: slug)
        if let old = errorWatchers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(old)
        }
        errorWatchers[key] = NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification,
            object: context, queue: .main
        ) { [weak self, weak context] _ in
            MainActor.assumeIsolated {
                guard let self, let context,
                      self.loadedContexts[spaceID]?[slug]?.context === context
                else { return }
                let failed = context.errors.contains { error in
                    let e = error as NSError
                    return e.domain == WKWebExtensionContext.errorDomain
                        && e.code == WKWebExtensionContext.Error
                            .backgroundContentFailedToLoad.rawValue
                }
                guard failed else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.revive(spaceID: spaceID, slug: slug, context: context)
                    }
                }
            }
        }
    }

    private func revive(
        spaceID: UUID, slug: String, context: WKWebExtensionContext
    ) {
        let key = watchKey(spaceID: spaceID, slug: slug)
        guard let loaded = loadedContexts[spaceID]?[slug],
              loaded.context === context,
              let controller = controllers[spaceID],
              Date().timeIntervalSince(revived[key] ?? .distantPast) > 60
        else { return }
        revived[key] = Date()
        do {
            try controller.unload(context)
            // Same context, so the generation stays: pages keep their API
            // objects. The new background's lifetime is what tells their ports
            // to reconnect (899/worker recovery).
            workerRecovery.restarted(
                ExtensionWorkerRecovery.Key(spaceID: spaceID, slug: slug),
                replacingContext: false
            )
            try controller.load(context)
            watchErrors(context, spaceID: spaceID, slug: slug)
            Log.extensions.notice(
                "revived extension \(slug) in space \(spaceID) after its worker failed"
            )
            onActionsChanged?()
        } catch {
            loadedContexts[spaceID]?[slug] = nil
            onActionsChanged?()
            Log.extensions.error(
                "could not revive \(slug) in space \(spaceID): \(String(describing: error))"
            )
        }
    }

    // MARK: - ExtensionControllerProviding

    public func extensionControllerHandle(for space: Space) -> ExtensionControllerHandle? {
        // Attach a controller to *every* web view at creation, even when the
        // Space has no extensions yet. `WKWebViewConfiguration.webExtensionController`
        // can only be set at creation and never added afterward, so without this
        // a tab opened before an extension is enabled could never run it. An
        // empty controller is cheap; this is the model Safari uses. Enabling an
        // extension later loads it into the controller the live views already
        // reference, so a reload is enough to activate it on existing tabs.
        prepare(space)
    }

    // MARK: -

    private func makeConfiguration(for space: Space)
        -> WKWebExtensionController.Configuration
    {
        // A private Space keeps nothing on disk, extensions included: a default
        // (non-persistent) configuration over a non-persistent data store. Every
        // other Space gets persistent per-identifier storage keyed to the same
        // id as its website data store, so extension data lands beside the
        // cookies it belongs with (3.3).
        let configuration: WKWebExtensionController.Configuration
        if space.isPrivate {
            // A non-persistent configuration already defaults to a
            // non-persistent data store, so nothing survives a quit.
            configuration = .nonPersistent()
            dataStores[space.id] = .nonPersistent()
        } else {
            configuration = WKWebExtensionController.Configuration(identifier: space.dataStoreID)
            let store = WKWebsiteDataStore(forIdentifier: space.dataStoreID)
            configuration.defaultWebsiteDataStore = store
            dataStores[space.id] = store
        }
        // Extension pages built from this controller's configuration — popup,
        // docked panel, offscreen document — need the capture channel too.
        // The controller copies the configuration at init, so it must be set
        // here, before the controller exists.
        let views = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        // Its own configuration starts with WebKit's default store; the
        // extension's pages keep what they store where the Space does.
        if let store = dataStores[space.id] { views.websiteDataStore = store }
        // The same user agent as the tabs, to the letter. WebKit gives workers
        // the user agent of the last page that loaded and, when it differs,
        // stops the running workers to apply it — and never starts an
        // extension's worker again: the first page a tab loaded left Bitwarden's
        // popup loading for ever. Search does the same.
        views.applicationNameForUserAgent = UserAgentPreference.safariVersionToken
        capture.attach(views.userContentController)
        configuration.webViewConfiguration = views
        return configuration
    }
}

// MARK: - WKWebExtensionControllerDelegate (7.3b)

extension WebKitExtensionHost: WKWebExtensionControllerDelegate {
    public func webExtensionController(
        _ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        guard let spaceID = controllerSpace[ObjectIdentifier(controller)] else { return [] }
        return [windowAdapter(forSpace: spaceID)] + (popouts[spaceID] ?? [])
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        guard let spaceID = controllerSpace[ObjectIdentifier(controller)] else { return nil }
        if let key = popouts[spaceID]?.first(where: \.isKey) { return key }
        return windowAdapter(forSpace: spaceID)
    }

    /// The shim's own native endpoint (`chord`) is answered in-process. Any
    /// other name is a Chrome native-messaging host installed on this Mac and
    /// is only run when the extension's own manifest asked for it.
    public func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for context: WKWebExtensionContext
    ) async throws -> Any? {
        if applicationIdentifier == nil || applicationIdentifier == ExtensionShims.application {
            guard let (spaceID, _) = locate(context) else {
                throw ExtensionNative.Refused(why: "Extension context is not loaded.")
            }
            return try await ExtensionShimBroker.answer(
                message, context: context, spaceID: spaceID, host: self
            )
        }
        guard let applicationIdentifier else { return nil }
        guard let (spaceID, slug) = locate(context),
              let loaded = loadedContexts[spaceID]?[slug],
              ExtensionShims.asksForNative(
                in: loaded.installed.resourceURL, context: context
              )
        else {
            throw ExtensionNative.Refused(
                why: "Access to native messaging requires the nativeMessaging permission."
            )
        }
        return try await ExtensionNative.send(
            message, to: applicationIdentifier, from: context.uniqueIdentifier
        )
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for context: WKWebExtensionContext
    ) async throws {
        // The shim only opens this port to find what ports share; it is not a
        // host and has nothing to keep.
        if port.applicationIdentifier == nil
            || port.applicationIdentifier == ExtensionShims.application {
            return
        }
        // A worker's WebSocket is made by the browser, not by WebKit (see
        // ExtensionSocket). It is not a Mac native host and needs no
        // nativeMessaging permission.
        if port.applicationIdentifier == ExtensionSocket.name {
            ExtensionSocket.connect(port, from: context)
            return
        }
        guard let applicationIdentifier = port.applicationIdentifier else { return }
        guard let (spaceID, slug) = locate(context),
              let loaded = loadedContexts[spaceID]?[slug],
              ExtensionShims.asksForNative(
                in: loaded.installed.resourceURL, context: context
              )
        else {
            throw ExtensionNative.Refused(
                why: "Access to native messaging requires the nativeMessaging permission."
            )
        }
        try ExtensionNative.connect(
            port, named: applicationIdentifier, from: context.uniqueIdentifier
        )
    }

    // MARK: - New tabs and options pages

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext
    ) async throws -> (any WKWebExtensionTab)? {
        guard let url = configuration.url else { return nil }
        let spaceID = (configuration.window as? ExtensionWindowAdapter)?.spaceID
            ?? locate(context)?.spaceID
        guard let spaceID,
              let snapshot = tabModel?.extensionCreateTab(
                url: url, inSpace: spaceID, active: configuration.shouldBeActive
              )
        else { return nil }
        return tabAdapter(for: snapshot.id, inSpace: spaceID)
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for context: WKWebExtensionContext
    ) async throws -> (any WKWebExtensionWindow)? {
        Log.extensions.debug(
            "windows.create from \(context.uniqueIdentifier): type \(configuration.windowType.rawValue), \(configuration.tabURLs.map(\.absoluteString)), \(configuration.tabs.count) tabs"
        )
        guard let spaceID = locate(context)?.spaceID, let model = tabModel else {
            return nil
        }
        // A private window isn't something an extension can have here: its
        // pages would land in the normal Space's store while the extension
        // believed them private. Refused, as Chrome refuses without incognito.
        guard !configuration.shouldBePrivate else {
            throw NSError(
                domain: "Chord", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Private windows can't be opened by extensions."]
            )
        }

        if let popout = openPopout(
            configuration, for: context, controller: controller, spaceID: spaceID
        ) {
            return popout
        }

        // Chord's WebExtension "window" is a Space (ADR 011), so a requested
        // window is a tab home in the active Space. Callers get a real window
        // id and working tabs; they do not get a second OS window on the same
        // Space, which the tab/window adapters cannot tell apart.
        for (index, url) in configuration.tabURLs.enumerated() {
            _ = model.extensionCreateTab(
                url: url, inSpace: spaceID, active: index == 0
            )
        }
        for asked in configuration.tabs {
            guard let tab = asked as? ExtensionTabAdapter,
                  let snapshot = model.extensionTab(tab.tabID),
                  snapshot.spaceID != spaceID
            else { continue }
            model.extensionMoveTab(tab.tabID, toSpace: spaceID, at: snapshot.index)
        }
        if configuration.tabURLs.isEmpty && configuration.tabs.isEmpty {
            _ = model.extensionCreateTab(
                url: URL(string: "about:blank")!, inSpace: spaceID, active: true
            )
        }
        return windowAdapter(forSpace: spaceID)
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor context: WKWebExtensionContext
    ) async throws {
        guard let url = context.optionsPageURL,
              let spaceID = locate(context)?.spaceID
        else { return }
        _ = tabModel?.extensionCreateTab(url: url, inSpace: spaceID, active: true)
    }

    // MARK: - Action updates (7.5a)

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        // We do not need the action here — `actions(in:)` rebuilds from the
        // current state — only the signal that something changed, so the UI
        // re-reads. Cheap and keeps a single source of truth.
        guard locate(context) != nil else { return }
        onActionsChanged?()
    }

    // MARK: - Popup presentation (7.5b)

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (((any Error)?) -> Void)
    ) {
        // Both a user click (via `presentAction`) and an extension-initiated
        // popup land here. WebKit's own popover is closed and the page is
        // loaded in a view built from the extension's configuration instead:
        // for some extensions WebKit's popup cannot reach the worker.
        guard let (spaceID, slug) = locate(context),
              let anchor = actionAnchors[spaceID]?[slug]?.view,
              let url = action.popupWebView?.url ?? popupURL(for: context)
        else {
            completionHandler(nil)
            return
        }
        action.closePopup()
        showPopup(url, for: context, from: anchor, spaceID: spaceID)
        completionHandler(nil)
    }

    /// A popup-type window of the extension's own page, as its own small
    /// window with its own id, as Chrome and Search make it (see
    /// ExtensionPopoutWindow). Nil for anything else — tabs to move in, a
    /// normal window, a website — which keeps opening as tabs in the Space.
    fileprivate func openPopout(
        _ configuration: WKWebExtension.WindowConfiguration,
        for context: WKWebExtensionContext, controller: WKWebExtensionController,
        spaceID: UUID
    ) -> ExtensionPopoutWindow? {
        guard configuration.windowType == .popup, configuration.tabs.isEmpty,
              let url = configuration.tabURLs.first, configuration.tabURLs.count == 1,
              url.scheme?.lowercased() == context.baseURL.scheme?.lowercased(),
              url.host()?.lowercased() == context.baseURL.host()?.lowercased()
        else { return nil }
        guard let popout = ExtensionPopoutWindow(
            url: url, frame: configuration.frame, context: context,
            controller: controller, host: self, spaceID: spaceID,
            focused: configuration.shouldBeFocused
        ) else { return nil }
        popout.onClosed = { [weak self] closed in
            self?.popouts[closed.spaceID]?.removeAll { $0 === closed }
        }
        popouts[spaceID, default: []].append(popout)
        Log.extensions.notice("opened popup window \(url.absoluteString)")
        return popout
    }

    /// An extension's popup windows go with it, as in Search: unloaded, its
    /// pages would be left talking to a context that is gone.
    private func closePopouts(of context: WKWebExtensionContext, in spaceID: UUID) {
        for popout in popouts[spaceID] ?? [] where popout.context === context {
            popout.close()
        }
    }

    /// Shows an extension's popup and tells the window it is up, then down.
    /// `onClose` is set only after `show`: `show` first closes any popup
    /// already up, which fires `onClose` — set before, it was used up at once,
    /// "closed" never reached the window, and a folded sidebar stayed out.
    private func showPopup(
        _ url: URL, for context: WKWebExtensionContext, from anchor: NSView?,
        spaceID: UUID
    ) {
        let window = anchor?.window
        ExtensionPopup.shared.show(url, for: context, from: anchor, host: self, spaceID: spaceID)
        guard ExtensionPopup.shared.isUp else { return }
        ExtensionPopup.shared.onClose = { [weak self] in
            self?.onPopupVisibilityChanged?(window, false)
        }
        onPopupVisibilityChanged?(window, true)
    }

    private func popupURL(for context: WKWebExtensionContext) -> URL? {
        guard let action = context.webExtension.manifest["action"] as? [String: Any],
              let path = action["default_popup"] as? String
        else { return nil }
        return URL(string: path, relativeTo: context.baseURL)
    }

    // MARK: - Permission prompts (7.5c)

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        guard let (spaceID, slug) = locate(context) else {
            completionHandler([], nil)
            return
        }
        enqueuePermission(
            spaceID: spaceID, slug: slug, kind: .permission,
            values: permissions.map(\.rawValue),
            displayName: context.webExtension.displayName
        ) { allow in completionHandler(allow ? permissions : [], nil) }
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        guard let (spaceID, slug) = locate(context) else {
            completionHandler([], nil)
            return
        }
        enqueuePermission(
            spaceID: spaceID, slug: slug, kind: .url,
            values: urls.map(\.absoluteString),
            displayName: context.webExtension.displayName
        ) { allow in completionHandler(allow ? urls : [], nil) }
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        guard let (spaceID, slug) = locate(context) else {
            completionHandler([], nil)
            return
        }
        enqueuePermission(
            spaceID: spaceID, slug: slug, kind: .matchPattern,
            values: matchPatterns.map(\.string),
            displayName: context.webExtension.displayName
        ) { allow in completionHandler(allow ? matchPatterns : [], nil) }
    }
}

// MARK: - Popup lifecycle

/// The popover is AppKit's, and AppKit is the only thing that knows when it goes
/// away — it closes on click-outside, on Esc, and on its anchor leaving the
/// window. The UI needs the close as much as the open: a sidebar pinned open by a
/// popup that has already gone would never auto-hide again.
extension WebKitExtensionHost: NSPopoverDelegate {
    public func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === visiblePopover
        else { return }
        let window = visiblePopoverWindow
        visiblePopover = nil
        visiblePopoverWindow = nil
        onPopupVisibilityChanged?(window, false)
    }
}

/// A page no one sees, at an extension's origin, for clearing what the
/// extension kept there (`forgetData`). Ported from Search's HiddenPage.
@MainActor
private final class BlankExtensionPage: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private var loaded: CheckedContinuation<Bool, Never>?

    init(_ configuration: WKWebViewConfiguration) {
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        web.navigationDelegate = self
    }

    /// Whether an empty page at `base` loaded within `limit` seconds.
    func load(at base: URL, within limit: TimeInterval = 10) async -> Bool {
        await withCheckedContinuation { done in
            loaded = done
            web.loadHTMLString("<!doctype html>", baseURL: base)
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
                MainActor.assumeIsolated { self?.finish(false) }
            }
        }
    }

    private func finish(_ ok: Bool) {
        loaded?.resume(returning: ok)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) { finish(false) }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) { finish(false) }
}
