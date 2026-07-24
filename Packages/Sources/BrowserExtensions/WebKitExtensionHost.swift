import BrowserCore
import BrowserEngine
import Foundation
import WebKit

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
    // `private(set)` rather than `private` so the package's own tests can reach
    // the controllers through `@testable`; the handle's controller is internal
    // to the engine and cannot be read from here.
    private(set) var controllers: [UUID: WKWebExtensionController] = [:]

    private struct Loaded {
        let context: WKWebExtensionContext
        let descriptor: LoadedExtension
    }
    /// Loaded contexts, keyed by Space then by extension slug.
    private var loadedContexts: [UUID: [String: Loaded]] = [:]

    /// Fired on the main actor when an extension updates its action (7.5a).
    public var onActionsChanged: (@MainActor () -> Void)?

    /// Weakly-held anchor views for popovers (7.5b), keyed by Space then slug.
    /// Weak so a torn-down sidebar button auto-clears without an unregister call.
    private final class WeakView { weak var view: NSView?; init(_ v: NSView?) { view = v } }
    private var actionAnchors: [UUID: [String: WeakView]] = [:]

    // MARK: - Permissions (7.5c)

    /// Persists grants and reads them back at load. Injected by `AppEnvironment`;
    /// `nil` leaves grants live-only (they still work for the session, just are
    /// not re-applied next launch).
    public var permissionsRepository: (any GrantedPermissionsRepository)?

    /// Fired on the main actor when an extension asks for a permission (7.5c).
    public var onPermissionRequest: (@MainActor (PermissionRequest) -> Void)?

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

    public override init() { super.init() }

    public var preparedSpaceIDs: Set<UUID> { Set(controllers.keys) }

    @discardableResult
    public func prepare(_ space: Space) -> ExtensionControllerHandle {
        spaces[space.id] = space
        if let existing = controllers[space.id] {
            return ExtensionControllerHandle(existing)
        }

        let controller = WKWebExtensionController(configuration: makeConfiguration(for: space))
        controller.delegate = self
        controllers[space.id] = controller
        controllerSpace[ObjectIdentifier(controller)] = space.id
        Log.extensions.debug(
            "prepared extension controller for space \(space.id, privacy: .public)"
        )
        return ExtensionControllerHandle(controller)
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

    // MARK: - Loading (7.3)

    @discardableResult
    public func load(_ installed: InstalledExtension, in space: Space) async throws
        -> LoadedExtension
    {
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
        let context = WKWebExtensionContext(for: webExtension)
        // Stable per (Space, slug): the controller is already per-Space, so the
        // slug is enough to keep this extension's granted permissions and
        // storage across launches.
        context.uniqueIdentifier = installed.slug

        // Re-apply permissions the user granted in a previous session (7.5c),
        // before the extension starts, so content scripts and host access work
        // without re-prompting. Best-effort: a repo read failure just means the
        // user may be prompted again.
        if let grants = try? await permissionsRepository?.granted(
            slug: installed.slug, spaceID: space.id
        ) {
            reapply(grants, to: context)
        }

        do {
            try controller.load(context)
        } catch {
            throw ExtensionLoadError.controllerRejected(error)
        }

        let descriptor = LoadedExtension(
            slug: installed.slug,
            spaceID: space.id,
            displayName: webExtension.displayName,
            manifestVersion: webExtension.manifestVersion,
            hasBackgroundContent: webExtension.hasBackgroundContent,
            hasPersistentBackgroundContent: webExtension.hasPersistentBackgroundContent
        )
        loadedContexts[space.id, default: [:]][installed.slug] = Loaded(
            context: context, descriptor: descriptor
        )
        Log.extensions.notice(
            "loaded extension \(installed.slug, privacy: .public) in space \(space.id, privacy: .public)"
        )
        return descriptor
    }

    public func unload(slug: String, in space: Space) throws {
        guard let loaded = loadedContexts[space.id]?[slug] else { return }
        if let controller = controllers[space.id] {
            do {
                try controller.unload(loaded.context)
            } catch {
                throw ExtensionLoadError.controllerRejected(error)
            }
        }
        loadedContexts[space.id]?[slug] = nil
        Log.extensions.notice(
            "unloaded extension \(slug, privacy: .public) in space \(space.id, privacy: .public)"
        )
    }

    public func loadedExtensions(in space: Space) -> [LoadedExtension] {
        (loadedContexts[space.id] ?? [:]).values
            .map(\.descriptor)
            .sorted { $0.slug < $1.slug }
    }

    // MARK: - Toolbar actions (7.5a)

    public func actions(in space: Space) -> [ExtensionActionSnapshot] {
        (loadedContexts[space.id] ?? [:])
            .sorted { $0.key < $1.key }
            .compactMap { slug, loaded in
                // The default (tab-independent) action; `action(for: nil)` is
                // the toolbar action the header button represents.
                guard let action = loaded.context.action(for: nil) else { return nil }
                return snapshot(of: action, slug: slug, spaceID: space.id)
            }
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
        // Perform the action for the Space's active tab if there is one, so a
        // popup opens against the page the user is actually reading and the tab
        // is marked as having a user gesture. `nil` performs the default action.
        let activeTab = tabModel?.extensionActiveTab(inSpace: space.id)
        let adapter = activeTab.map { tabAdapter(for: $0.id, inSpace: space.id) }
        loaded.context.performAction(for: adapter)
    }

    // MARK: - Permissions (7.5c)

    public func resolvePermission(id: UUID, allow: Bool) {
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

    // MARK: - ExtensionControllerProviding

    public func extensionControllerHandle(for space: Space) -> ExtensionControllerHandle? {
        controllers[space.id].map(ExtensionControllerHandle.init)
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
        } else {
            configuration = WKWebExtensionController.Configuration(identifier: space.dataStoreID)
            configuration.defaultWebsiteDataStore =
                WKWebsiteDataStore(forIdentifier: space.dataStoreID)
        }
        return configuration
    }
}

// MARK: - WKWebExtensionControllerDelegate (7.3b)

extension WebKitExtensionHost: WKWebExtensionControllerDelegate {
    public func webExtensionController(
        _ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        guard let spaceID = controllerSpace[ObjectIdentifier(controller)] else { return [] }
        return [windowAdapter(forSpace: spaceID)]
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        guard let spaceID = controllerSpace[ObjectIdentifier(controller)] else { return nil }
        return windowAdapter(forSpace: spaceID)
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
        // popup land here. We show the ready-made popover — which wraps the
        // popup `WKWebView` — against the sidebar-header button registered for
        // this (Space, slug), keeping WebKit inside the host.
        guard let (spaceID, slug) = locate(context),
            let anchor = actionAnchors[spaceID]?[slug]?.view,
            let popover = action.popupPopover
        else {
            completionHandler(nil)
            return
        }
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        completionHandler(nil)
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
