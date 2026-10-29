import Foundation
import WebKit

/// A WebSocket for an extension's worker.
///
/// WebKit runs a service worker on its web process's main thread, and a
/// worker's WebSocket waits there synchronously for the main thread to set up
/// its channel: the worker waits on itself for ever and every page of the
/// extension freezes with it. 1Password opens one the moment a sign-in
/// succeeds.
///
/// So in a worker the shim's WebSocket is made here with `URLSession`, and its
/// frames go over a native port: text as it is, binary as base64. The Origin
/// and user agent are the ones Chrome would send.
@MainActor
enum ExtensionSocket {
    static let name = ExtensionShims.application + ".socket"

    private static let session = URLSession(
        configuration: .default, delegate: nil, delegateQueue: .main
    )
    /// Every socket that is up, by the context that opened it, held until it
    /// ends. By context rather than by extension id: the same extension in
    /// another Space has the same id and keeps its own sockets.
    private struct Live {
        let context: ObjectIdentifier
        let isOrphan: () -> Bool
        let end: () -> Void
    }
    private static var open: [ObjectIdentifier: Live] = [:]

    static var openCount: Int { open.count }

    static func connect(_ port: WKWebExtension.MessagePort, from context: WKWebExtensionContext) {
        endOrphans()
        let connection = Connection(
            port: port, origin: "chrome-extension://\(context.uniqueIdentifier)"
        )
        let key = ObjectIdentifier(connection)
        keep(key, context: ObjectIdentifier(context),
             isOrphan: { [weak connection] in connection?.isOrphan ?? true },
             end: { [weak connection] in connection?.end(tellingPort: true) })
        connection.onEnd = { forget(key) }
    }

    static func keep(
        _ key: ObjectIdentifier, context: ObjectIdentifier,
        isOrphan: @escaping () -> Bool, end: @escaping () -> Void
    ) {
        open[key] = Live(context: context, isOrphan: isOrphan, end: end)
    }

    static func forget(_ key: ObjectIdentifier) { open[key] = nil }

    /// Ends what a context left open. WebKit doesn't always call a port's
    /// disconnect handler when it unloads an extension, so without this its
    /// sockets would stay connected to their servers for the life of the app.
    static func endConnections(of context: WKWebExtensionContext) {
        endConnections(of: ObjectIdentifier(context))
    }

    static func endConnections(of context: ObjectIdentifier) {
        for (_, live) in open where live.context == context { live.end() }
    }

    /// Ends sockets whose port is gone, as ExtensionNative.stopOrphans does for
    /// native hosts. Run on every new connection.
    static func endOrphans() {
        for (_, live) in open where live.isOrphan() { live.end() }
    }

    @MainActor
    final class Connection: NSObject, URLSessionWebSocketDelegate {
        private let port: WKWebExtension.MessagePort
        private let origin: String
        private var task: URLSessionWebSocketTask?
        private var ended = false
        var onEnd: (() -> Void)?
        var isOrphan: Bool { port.isDisconnected }

        init(port: WKWebExtension.MessagePort, origin: String) {
            self.port = port
            self.origin = origin
            super.init()
            port.messageHandler = { [weak self] message, _ in
                MainActor.assumeIsolated { self?.take(message) }
            }
            port.disconnectHandler = { [weak self] _ in
                MainActor.assumeIsolated { self?.end(tellingPort: false) }
            }
            // WebKit loses a port a worker opens in its first moments; the
            // shim treats this as the sign that it arrived.
            post(["ready": true])
        }

        private func take(_ message: Any?) {
            guard let message = message as? [String: Any] else { return }
            if let word = message["__chordNative"] {
                if (word as? String) == "here?" { post(["__chordNative": "here"]) }
                return
            }
            if let address = message["open"] as? String {
                post(["ready": true])
                guard task == nil else { return }
                start(
                    address, protocols: message["protocols"] as? [String] ?? [],
                    userAgent: message["userAgent"] as? String
                )
            } else if let text = message["send"] as? String {
                task?.send(.string(text)) { _ in }
            } else if let encoded = message["sendBinary"] as? String,
                      let data = Data(base64Encoded: encoded) {
                task?.send(.data(data)) { _ in }
            } else if message["close"] != nil {
                let code = (message["close"] as? Int)
                    .flatMap(URLSessionWebSocketTask.CloseCode.init(rawValue:))
                    ?? .normalClosure
                let reason = (message["reason"] as? String).map { Data($0.utf8) }
                task?.cancel(with: code, reason: reason)
            }
        }

        private func start(
            _ address: String, protocols: [String], userAgent: String?
        ) {
            guard task == nil, let url = URL(string: address),
                  ["ws", "wss"].contains(url.scheme?.lowercased())
            else {
                fail()
                return
            }
            var request = URLRequest(url: url)
            request.setValue(origin, forHTTPHeaderField: "Origin")
            if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
            if !protocols.isEmpty {
                request.setValue(
                    protocols.joined(separator: ", "),
                    forHTTPHeaderField: "Sec-WebSocket-Protocol"
                )
            }
            let task = ExtensionSocket.session.webSocketTask(with: request)
            task.delegate = self
            self.task = task
            task.resume()
        }

        private func receive(from task: URLSessionWebSocketTask) {
            Task { [weak self] in
                while let message = try? await task.receive() {
                    guard let self, !self.ended else { return }
                    switch message {
                    case .string(let text): self.post(["text": text])
                    case .data(let data): self.post(["binary": data.base64EncodedString()])
                    @unknown default: break
                    }
                }
            }
        }

        private func post(_ message: [String: Any]) {
            guard !port.isDisconnected else { return }
            port.sendMessage(message, completionHandler: nil)
        }

        private func fail() {
            post(["failed": true])
            post(["closed": 1006, "reason": "", "clean": false])
            end(tellingPort: true)
        }

        func end(tellingPort: Bool) {
            guard !ended else { return }
            ended = true
            task?.cancel(with: .goingAway, reason: nil)
            if tellingPort, !port.isDisconnected { port.disconnect() }
            onEnd?()
        }

        nonisolated func urlSession(
            _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
            didOpenWithProtocol chosen: String?
        ) {
            MainActor.assumeIsolated {
                post(["opened": chosen ?? ""])
                receive(from: webSocketTask)
            }
        }

        nonisolated func urlSession(
            _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
        ) {
            MainActor.assumeIsolated {
                post([
                    "closed": closeCode.rawValue,
                    "reason": reason.map { String(decoding: $0, as: UTF8.self) } ?? "",
                    "clean": true,
                ])
                end(tellingPort: true)
            }
        }

        nonisolated func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
        ) {
            MainActor.assumeIsolated {
                guard !ended else { return }
                if error != nil {
                    fail()
                } else {
                    post(["closed": 1005, "reason": "", "clean": true])
                    end(tellingPort: true)
                }
            }
        }
    }
}
