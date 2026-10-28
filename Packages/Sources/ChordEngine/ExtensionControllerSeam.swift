import ChordCore
import Foundation
import WebKit

/// An opaque handle to a Space's web-extension controller.
///
/// The same trick as `AnyWebSurface`: the layers above the engine (Store, UI)
/// can hold and pass one of these, but the `WKWebExtensionController` inside
/// never crosses the seam. The extension host — the only other WebKit importer,
/// per the amended §7.1 — builds these; `WebKitEngine` unwraps them internally
/// when it attaches one to a per-Space configuration. See ADR 011.
public struct ExtensionControllerHandle {
    /// Internal to the engine package. `ChordExtensions` sets it (it imports
    /// WebKit too); nothing in Store or UI can name the type.
    let controller: WKWebExtensionController

    /// Adds the extension host's worker-recovery channel to a page's content
    /// controller (899/worker recovery). The host owns the handler objects; the
    /// engine only provides the controllers they must be installed on, because
    /// every tab makes its own. Nil for a handle built without a host.
    public var attachWorkerRecovery: ((WKUserContentController) -> Void)?

    /// Adds the extension host's screen-capture channel to a page's content
    /// controller. Every extension page the engine shows — an options page, a
    /// popup opened as a tab — posts through it.
    public var attachCapture: ((WKUserContentController) -> Void)?

    /// WebKit's display-capture question for an extension page: 1 for a
    /// screen, 2 for a window, 0 when Chord has no capture call in flight.
    /// Supplied by the host so the engine names no capture type.
    public var captureDisplayDecision: ((WKWebView) -> Int)?

    public init(
        _ controller: WKWebExtensionController,
        attachWorkerRecovery: ((WKUserContentController) -> Void)? = nil,
        attachCapture: ((WKUserContentController) -> Void)? = nil,
        captureDisplayDecision: ((WKWebView) -> Int)? = nil
    ) {
        self.controller = controller
        self.attachWorkerRecovery = attachWorkerRecovery
        self.attachCapture = attachCapture
        self.captureDisplayDecision = captureDisplayDecision
    }
}

/// Supplies the per-Space extension controller the engine attaches to a web
/// view's configuration.
///
/// Declared here, in the engine, so the engine can consume it — but its public
/// surface is WebKit-free (a `Space` in, an opaque handle out). That is what
/// lets `AppEnvironment`, in the WebKit-free Store, wire the host to the engine
/// without ever naming a `WK*` type. The host lives in `ChordExtensions`.
@MainActor
public protocol ExtensionControllerProviding: AnyObject {
    /// The controller for a Space, or `nil` when that Space has no extensions
    /// loaded — in which case the engine leaves `webExtensionController` unset
    /// and the configuration stays as cheap as it was before M7.
    func extensionControllerHandle(for space: Space) -> ExtensionControllerHandle?
}
