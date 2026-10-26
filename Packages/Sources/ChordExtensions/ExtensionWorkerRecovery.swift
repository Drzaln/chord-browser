import Foundation
import WebKit

/// Keeps an extension's ports pointed at the background that is actually
/// running (899/worker recovery).
///
/// **The problem.** Chrome queues `runtime.connect()` until the worker
/// registers its `runtime.onConnect` listener, and restarts a crashed MV3
/// worker on demand. WebKit does neither: a `connect()` that arrives while the
/// worker is starting comes back already disconnected (`No runtime.onConnect
/// listeners found`), and a worker that exits or crashes is not brought back
/// until something else wakes it. An extension that treats a failed port as a
/// failed operation — Bitwarden reports a correct master password as wrong —
/// breaks in a way no amount of UI polish can hide.
///
/// **The shape.** WebKit exposes no public "a background was created" callback,
/// but it does call a private delegate method before every background web view
/// it makes, including one woken inside the same context after an idle exit.
/// This type listens there and answers one question for the injected shim:
/// *is the background you are talking to still the one I started with?*
///
/// The answer is a **generation**, per (Space, extension):
/// - it starts at 0;
/// - it is raised whenever the context itself is replaced (unload + reload,
///   an install, a disable/enable) — a different context means different
///   WebKit API objects, so every old port is dead;
/// - an idle wake or a crash-retry inside the same context keeps the number
///   (WebKit replaces only the background), and is reported through the
///   background's **lifetime** instead: an observer that was waiting on the
///   retired web view is told the new generation as soon as the replacement
///   appears.
///
/// The shim registers an observer (`background.observe`) for the ports it
/// holds; when the answer differs from what it expected, it disconnects those
/// ports. The extension's own `onDisconnect` runs, Chrome-style, and it
/// reconnects to the live worker. Content scripts ask the same question through
/// a `WKScriptMessageHandlerWithReply` (`chordWorkerRecovery`) in the
/// extension's isolated world, because a content script has no
/// `sendNativeMessage`.
///
/// Nothing here can start an extension's code. It observes and reports; waking
/// a worker is WebKit's job, and `connect()` after the report does it.
@MainActor
public final class ExtensionWorkerRecovery: NSObject {
    public static let shared = ExtensionWorkerRecovery()

    /// The message name the shim's content-script copy posts to. Must match
    /// `webkit.messageHandlers.chordWorkerRecovery` in `ExtensionShimScript`.
    static let messageName = "chordWorkerRecovery"

    /// More observers than any real extension holds; a page that leaks them
    /// must not grow this without bound.
    static let observerLimit = 4096

    /// One extension in one Space. The same slug may be enabled in several
    /// Spaces, and each has its own controller, context and worker.
    public struct Key: Hashable, Sendable {
        public let spaceID: UUID
        public let slug: String

        public init(spaceID: UUID, slug: String) {
            self.spaceID = spaceID
            self.slug = slug
        }
    }

    private final class WeakContext {
        weak var value: WKWebExtensionContext?
        init(_ value: WKWebExtensionContext) { self.value = value }
    }

    private final class Background {
        weak var view: WKWebView?
        let lifetime = UUID()
        init(_ view: WKWebView) { self.view = view }
    }

    private struct Observation {
        var lifetime: UUID?
        let reply: (Int?) -> Void
    }

    /// Every user content controller a page in this app is built with, and the
    /// Space whose controller it belongs to. Weak: a closed tab's controller
    /// goes away by itself. A handler is attached only to controllers of its
    /// own Space — two Spaces run the same extension under the same isolated
    /// world name, and WebKit allows one handler per name per world.
    private final class WeakController {
        weak var value: WKUserContentController?
        let spaceID: UUID
        init(_ value: WKUserContentController, spaceID: UUID) {
            self.value = value
            self.spaceID = spaceID
        }
    }
    private var controllers: [ObjectIdentifier: WeakController] = [:]

    private var handlers: [Key: Handler] = [:]
    private var contexts: [Key: WeakContext] = [:]
    private var backgrounds: [Key: Background] = [:]
    private var generations: [Key: Int] = [:]
    private var waiting: [Key: [String: Observation]] = [:]
    /// Which key a context belongs to, for the delegate callback that carries
    /// only the context.
    private var keys: [ObjectIdentifier: Key] = [:]

    public override init() {
        super.init()
    }

    // MARK: - Registration

    /// The generation an extension's pages should expect. A new context starts
    /// at 0; every replacement raises it.
    public func generation(for key: Key) -> Int { generations[key, default: 0] }

    /// Test/diagnostic: the lifetime of the background WebKit last created for
    /// this extension. `nil` means the private creation callback has not run.
    func backgroundLifetime(for key: Key) -> UUID? { backgrounds[key]?.lifetime }

    /// Adds the handlers of `spaceID`'s extensions to a page's controller, in
    /// the isolated world WebKit gives their content scripts. Safe to call for
    /// every view: the same controller is never registered twice.
    public func attach(spaceID: UUID, controller: WKUserContentController) {
        let identity = ObjectIdentifier(controller)
        if let known = controllers[identity], known.spaceID == spaceID {
            // Already known: only handlers added since could be missing.
            for handler in handlers.values where handler.key.spaceID == spaceID {
                handler.attach(controller)
            }
            return
        }
        controllers[identity] = WeakController(controller, spaceID: spaceID)
        for handler in handlers.values where handler.key.spaceID == spaceID {
            handler.attach(controller)
        }
    }

    /// Every controller still alive for a Space.
    private func liveControllers(for spaceID: UUID) -> [WKUserContentController] {
        var dead: [ObjectIdentifier] = []
        var live: [WKUserContentController] = []
        for (identity, entry) in controllers {
            guard let controller = entry.value else {
                dead.append(identity)
                continue
            }
            if entry.spaceID == spaceID { live.append(controller) }
        }
        for identity in dead { controllers[identity] = nil }
        return live
    }

    /// Call **before** `controller.load(context)`: WebKit can create the
    /// background synchronously from inside that call, and a handler registered
    /// afterwards would miss it. The returned closure undoes the registration
    /// if the load fails.
    public func register(
        _ context: WKWebExtensionContext, spaceID: UUID, slug: String
    ) -> () -> Void {
        let key = Key(spaceID: spaceID, slug: slug)
        let previousContext = contexts[key]
        let previousBackground = backgrounds[key]
        let addedHandler = handlers[key] == nil
        contexts[key] = WeakContext(context)
        keys[ObjectIdentifier(context)] = key
        if addedHandler {
            // The content world WebKit runs this extension's isolated scripts
            // in is named after its Chrome identifier, which is what
            // `context.uniqueIdentifier` carries.
            let handler = Handler(
                key: key, owner: self,
                worldName: "WebExtension-" + context.uniqueIdentifier
            )
            handlers[key] = handler
            for controller in liveControllers(for: spaceID) { handler.attach(controller) }
        }
        Log.extensions.debug(
            "worker recovery: registered \(slug) in space \(spaceID) at generation \(generation(for: key))"
        )
        return { [weak self, weak context] in
            guard let self, let context, self.contexts[key]?.value === context else { return }
            self.keys[ObjectIdentifier(context)] = nil
            if addedHandler { self.unregister(key) }
            self.contexts[key] = previousContext
            self.backgrounds[key] = previousBackground
        }
    }

    /// The extension is gone from this Space (disabled, removed, or replaced).
    /// Detaches the handler so future tabs carry nothing of it, and answers
    /// every waiter with nothing (a cancellation).
    public func unregister(_ key: Key) {
        if let handler = handlers.removeValue(forKey: key) {
            for controller in liveControllers(for: key.spaceID) { handler.detach(controller) }
        }
        if let context = contexts[key]?.value { keys[ObjectIdentifier(context)] = nil }
        contexts[key] = nil
        backgrounds[key] = nil
        let replies = waiting.removeValue(forKey: key) ?? [:]
        replies.values.forEach { $0.reply(nil) }
        Log.extensions.debug(
            "worker recovery: unregistered \(key.slug) in space \(key.spaceID)"
        )
    }

    /// WebKit made a new background web view — first start, idle wake, or a
    /// retry after a crash. Same context, new lifetime: observers bound to the
    /// retired view are told to reconnect.
    public func created(_ view: WKWebView, in context: WKWebExtensionContext) {
        guard let key = keys[ObjectIdentifier(context)],
            contexts[key]?.value === context,
            context.isLoaded,
            backgrounds[key]?.view !== view
        else { return }
        backgrounds[key] = Background(view)
        createdWorker(key, lifetime: backgrounds[key]!.lifetime)
    }

    /// Raises the generation. `replacingContext: false` is the same-context
    /// revive (`controller.unload` + `controller.load` on one instance): pages
    /// keep their WebKit API objects, only the background was replaced, which
    /// the lifetime already reports. A fresh context (`true`) makes every
    /// previous port invalid.
    public func restarted(_ key: Key, replacingContext: Bool = true) {
        if replacingContext {
            generations[key] = generation(for: key) + 1
        }
        backgrounds[key] = nil
        let replies = waiting.removeValue(forKey: key) ?? [:]
        replies.values.forEach { $0.reply(generation(for: key)) }
        Log.extensions.debug(
            "worker recovery: \(key.slug) generation \(generation(for: key))"
            + (replacingContext ? " (context replaced)" : " (background replaced)")
        )
    }

    // MARK: - Observing

    /// Answers at once when the caller is already stale, otherwise holds the
    /// request until this extension's worker is replaced. `nil` means the
    /// observation was cancelled or its extension is gone.
    public func observe(_ key: Key, generation: Int, token: String) async -> Int? {
        await withCheckedContinuation { done in
            observe(
                key, generation: generation, token: token,
                lifetime: lifetime(for: key)
            ) { done.resume(returning: $0) }
        }
    }

    private func observe(
        _ key: Key, generation: Int, token: String, lifetime: UUID?,
        reply: @escaping (Int?) -> Void
    ) {
        let current = self.generation(for: key)
        guard !token.isEmpty, token.count <= 128, generation >= 0, generation <= current
        else {
            reply(nil)
            return
        }
        if generation < current {
            reply(current)
            return
        }
        cancel(key, token: token)
        guard waiting[key, default: [:]].count < Self.observerLimit else {
            reply(nil)
            return
        }
        waiting[key, default: [:]][token] = Observation(lifetime: lifetime, reply: reply)
    }

    public func cancel(_ key: Key, token: String) {
        waiting[key]?.removeValue(forKey: token)?.reply(nil)
        if waiting[key]?.isEmpty == true { waiting[key] = nil }
    }

    /// The live background's identity, read through WebKit's private accessor:
    /// `loadBackgroundContent` reports only an error, not whether it replaced
    /// anything, and the view's identity is what distinguishes "running" from
    /// "about to be woken".
    private func lifetime(for key: Key) -> UUID? {
        guard let context = contexts[key]?.value, context.isLoaded else { return nil }
        let selector = NSSelectorFromString("_backgroundWebView")
        guard context.responds(to: selector),
            let view = context.perform(selector)?.takeUnretainedValue() as? WKWebView
        else { return nil }
        created(view, in: context)
        return backgrounds[key]?.lifetime
    }

    private func createdWorker(_ key: Key, lifetime: UUID) {
        var replies: [(Int?) -> Void] = []
        for (token, var observation) in waiting[key] ?? [:] {
            if observation.lifetime == nil {
                // Registered while no background existed: the caller is waiting
                // for this one, not for a retired one.
                observation.lifetime = lifetime
                waiting[key]?[token] = observation
            } else if observation.lifetime != lifetime {
                waiting[key]?.removeValue(forKey: token)
                replies.append(observation.reply)
            }
        }
        // Old observers are answered before callbacks can register new ports.
        replies.forEach { $0(generation(for: key)) }
    }

    // MARK: - The content-script bridge

    /// Receives `{ generation, token }` or `{ token, cancel: true }` from the
    /// shim's content-script copy and answers with the current generation, or
    /// `nil` when the observation was cancelled. The identity comes from the
    /// handler's key, never from the message.
    @MainActor
    private final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        let key: Key
        unowned let owner: ExtensionWorkerRecovery
        let world: WKContentWorld
        /// Which controllers this handler is on. Weak, and checked on attach:
        /// WebKit throws, uncatchably, if one name is added twice.
        private let attached = NSHashTable<WKUserContentController>.weakObjects()

        init(key: Key, owner: ExtensionWorkerRecovery, worldName: String) {
            self.key = key
            self.owner = owner
            // WebKit's shared named world for an extension's isolated scripts.
            // The name matches the context's Chrome identifier, so the shim
            // injected into a content script lands in the same world.
            self.world = .world(name: worldName)
            super.init()
        }

        func attach(_ controller: WKUserContentController) {
            guard !attached.contains(controller) else { return }
            attached.add(controller)
            controller.addScriptMessageHandler(
                self, contentWorld: world, name: ExtensionWorkerRecovery.messageName
            )
        }

        func detach(_ controller: WKUserContentController) {
            guard attached.contains(controller) else { return }
            attached.remove(controller)
            controller.removeScriptMessageHandler(
                forName: ExtensionWorkerRecovery.messageName, contentWorld: world
            )
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor (Any?, String?) -> Void
        ) {
            guard let request = message.body as? [String: Any],
                let token = request["token"] as? String,
                !token.isEmpty, token.count <= 128
            else {
                replyHandler(nil, "Invalid observer")
                return
            }
            guard owner.handlers[key] === self else {
                replyHandler(nil, "Extension registration was replaced")
                return
            }
            if request["cancel"] as? Bool == true {
                owner.cancel(key, token: token)
                replyHandler(nil, nil)
                return
            }
            guard owner.contexts[key]?.value?.isLoaded == true else {
                replyHandler(nil, "Extension context is not loaded")
                return
            }
            guard let generation = request["generation"] as? Int, generation >= 0,
                generation <= owner.generation(for: key)
            else {
                replyHandler(nil, "Invalid worker generation")
                return
            }
            Task { @MainActor in
                let answer = await owner.observe(
                    key, generation: generation, token: token
                )
                replyHandler(answer, nil)
            }
        }
    }
}
