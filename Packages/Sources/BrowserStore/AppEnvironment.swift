import BrowserCore
import BrowserEngine
import BrowserExtensions
import BrowserLogging
import BrowserPersistence
import BrowserSecrets
import Foundation

/// Constructed once at launch and passed down. No singletons, no service
/// locator, and services never travel through the SwiftUI environment (3.6).
@MainActor
public struct AppEnvironment {
    public let store: TabStore
    public let downloads: DownloadsStore
    /// Present when the extensions flag is on (M7, 7.4). The app uses it to list,
    /// install, enable, and disable extensions. `nil` when extensions are off.
    public let extensions: ExtensionsService?
    /// Retained strongly here: the engine holds the provider `weak` so a live
    /// browser must keep the host alive somewhere, and this environment is the
    /// object with the app's lifetime. `nil` when the extensions flag is off,
    /// in which case no host exists and the engine attaches no controller (M7).
    public let extensionHost: (any ExtensionHost)?
    /// The native content blocker (§4.8, C2), present when the flag is on.
    /// Retained for the app's lifetime; it owns the compiled rule list.
    public let contentBlocker: ContentBlocker?

    public init(
        store: TabStore,
        downloads: DownloadsStore,
        extensionHost: (any ExtensionHost)? = nil,
        extensions: ExtensionsService? = nil,
        contentBlocker: ContentBlocker? = nil
    ) {
        self.store = store
        self.downloads = downloads
        self.extensionHost = extensionHost
        self.extensions = extensions
        self.contentBlocker = contentBlocker
    }

    /// The real, on-disk configuration.
    public static func live(
        applicationName: String = "Browser"
    ) throws -> AppEnvironment {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: applicationName)

        // File-backed logging (BROWSER_SPEC 3.7). Every os.Logger line is
        // mirrored to a rotating file here, because `log show`/`log stream` are
        // unreadable on this machine — the file is where debugging is read back.
        AppLog.install(fileURL: support.appending(path: "Logs/browser.log"))

        let database = try BrowserDatabase.open(at: support.appending(path: "browser.sqlite"))

        let engine = WebKitEngine(
            configuration: EngineConfiguration(
                faviconCacheDirectory: support.appending(path: "Favicons"),
                applicationName: applicationName
            )
        )

        // Extensions (M7). Shipped — its feature flag was deleted (§7.4), so the
        // per-Space controller wiring is always present.
        let host = WebKitExtensionHost()
        engine.extensionControllerProvider = host
        let extensionHost: (any ExtensionHost)? = host

        // Native content blocking (§4.8). Shipped — flag deleted. The compile
        // runs off-main inside WebKit; views built before it finishes are
        // retrofitted by `applyContentRuleList`.
        let blocker = ContentBlocker()
        let contentBlocker: ContentBlocker? = blocker
        Task {
            // Attach the currently-active lists first (the cached full set, or
            // the seed on first launch), then let the weekly refresh fetch the
            // full lists and swap in when ready (C3).
            engine.applyContentRuleLists(await blocker.activeLists())
            let refreshed = await blocker.refreshIfDue()
            if !refreshed.isEmpty {
                engine.applyContentRuleLists(refreshed)
            }
        }

        let repository = SQLiteTabRepository(database: database)
        let history = SQLiteHistoryRepository(database: database)
        let windowLayouts = SQLiteWindowLayoutRepository(database: database)

        let store = TabStore(
            engine: engine,
            repository: repository,
            spaceRepository: repository,
            historyRepository: history,
            archiveRepository: history,
            folderRepository: repository,
            windowLayoutRepository: windowLayouts,
            clock: SystemClock()
        )
        // Ask-once-per-site camera/mic decisions (non-spec: user-requested),
        // persisted across launches like the extension grants.
        store.sitePermissions = SQLiteSitePermissionsRepository(database: database)

        // Wire the tab/window model both ways (7.3b) when extensions are on. The
        // store is the model the adapters read; the engine, forwarded as an
        // existential, is the provider that vends a pane's live web view. Neither
        // line names a WebKit type, so the Store stays WebKit-free.
        host.tabModel = store
        host.paneWebViewProvider = engine
        store.extensionHost = host
        // An action update (badge, icon, enabled-ness) bumps an observable token
        // on the store so the sidebar header re-reads `actions(in:)` (7.5a). No
        // action data flows through here — just the trigger.
        host.onActionsChanged = { [weak store] in store?.extensionActionsToken &+= 1 }

        // Permission prompts (7.5c): the host surfaces a WebKit-free request,
        // which the store queues for the UI's grant/deny sheet. The grants
        // repository lets the host persist a grant and re-apply it next launch.
        host.permissionsRepository = SQLiteGrantedPermissionsRepository(database: database)
        host.onPermissionRequest = { [weak store] request in
            store?.pendingPermissionRequests.append(request)
        }
        // An extension popup must pin its window's revealed sidebar open while it
        // is on screen — the popup hangs off the sidebar button, so an auto-hide
        // mid-use closes it. Broadcast rather than call: the host is app-wide but
        // only one window's sidebar should be pinned, and every window's view can
        // filter on the window it carries. A direct closure would be
        // last-writer-wins across windows.
        host.onPopupVisibilityChanged = { window, isVisible in
            NotificationCenter.default.post(
                name: .extensionPopupVisibilityChanged,
                object: window,
                userInfo: [ExtensionPopupVisibility.isVisibleKey: isVisible]
            )
        }

        // After host access is granted on enable, reload so content scripts
        // inject into the page that is already open.
        host.onHostAccessChanged = { [weak store] spaceID in
            store?.reloadTabs(inSpace: spaceID)
        }

        // The password vault (V5). Metadata in SQLite beside everything else,
        // secrets in the Keychain — the split that keeps a password out of
        // database backups and `.recover` dumps. `.strict` origins: HTTPS only.
        store.vault = CredentialVault(
            repository: SQLiteCredentialRepository(database: database),
            secrets: KeychainSecretStore()
        )
        // Reveal in Settings is gated on Touch ID (falling back to the device
        // passcode). App-level, not Keychain-enforced — the OS-enforced form
        // needs an entitlement this signing setup cannot have; see
        // `KeychainSecretStore`.
        store.authenticator = BiometricAuthenticator()

        // Drops any Keychain item whose credential row has gone — an
        // unreferenced secret is a password the user cannot see in Settings and
        // therefore cannot delete.
        Task { [vault = store.vault] in
            _ = try? await vault?.reconcile()
        }

        // The library, the host, and the enablement store, coordinated (7.4).
        let extensionsService = ExtensionsService(
            installer: ExtensionInstaller(
                extensionsDirectory: support.appending(path: "Extensions")
            ),
            host: host,
            enablement: SQLiteExtensionEnablementRepository(database: database)
        )
        // Re-load enabled extensions once the Spaces they belong to have been
        // restored. `restore()` invokes this at its end.
        store.afterRestore = { [weak store] in
            guard let store else { return }
            await extensionsService.restoreEnabled(spaces: store.spaces)
        }

        return AppEnvironment(
            store: store,
            downloads: DownloadsStore(coordinator: engine.downloads),
            extensionHost: extensionHost,
            extensions: extensionsService,
            contentBlocker: contentBlocker
        )
    }
}
