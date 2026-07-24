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
public final class WebKitExtensionHost: ExtensionHost {
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

    public init() {}

    public var preparedSpaceIDs: Set<UUID> { Set(controllers.keys) }

    @discardableResult
    public func prepare(_ space: Space) -> ExtensionControllerHandle {
        if let existing = controllers[space.id] {
            return ExtensionControllerHandle(existing)
        }

        let controller = WKWebExtensionController(configuration: makeConfiguration(for: space))
        controllers[space.id] = controller
        Log.extensions.debug(
            "prepared extension controller for space \(space.id, privacy: .public)"
        )
        return ExtensionControllerHandle(controller)
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

        do {
            try controller.load(context)
        } catch {
            throw ExtensionLoadError.controllerRejected(error)
        }

        let descriptor = LoadedExtension(
            slug: installed.slug,
            spaceID: space.id,
            displayName: webExtension.displayName,
            manifestVersion: webExtension.manifestVersion
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
