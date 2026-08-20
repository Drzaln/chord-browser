import Foundation
import Network

/// A minimal localhost HTTP server for end-to-end tests.
///
/// End-to-end tests drive a real `WKWebView`, and a real web view needs a real
/// origin — `about:blank` sets no cookies and has no title. Serving from
/// localhost keeps the tests hermetic: no network, no rate limits, no flake
/// from someone else's uptime.
public actor TestHTTPServer {
    public struct Route: Sendable {
        public let path: String
        public let html: String
        /// Anything WebKit cannot render turns the navigation into a download,
        /// which is the only way to exercise `WKDownloadDelegate` end to end.
        public let contentType: String
        public let extraHeaders: [String: String]

        public init(
            path: String,
            html: String,
            contentType: String = "text/html; charset=utf-8",
            extraHeaders: [String: String] = [:]
        ) {
            self.path = path
            self.html = html
            self.contentType = contentType
            self.extraHeaders = extraHeaders
        }
    }

    /// A route that downloads rather than renders.
    public static func attachment(
        path: String, filename: String, body: String
    ) -> Route {
        Route(
            path: path,
            html: body,
            contentType: "application/octet-stream",
            extraHeaders: ["Content-Disposition": "attachment; filename=\"\(filename)\""]
        )
    }

    private let listener: NWListener
    private var routes: [String: Route] = [:]
    private var connections: [NWConnection] = []

    /// Every request's path and headers, most recent first, keys lower-cased.
    /// Lets a test assert on what was actually *sent* rather than only on what
    /// was rendered — the User-Agent is the reason this exists (9.6).
    public private(set) var receivedRequests: [(path: String, headers: [String: String])] = []

    /// A header from the most recent request for a given path.
    ///
    /// Per path on purpose. A page load is followed by requests for its
    /// favicon and anything else it references, and those do not all come from
    /// WebKit — the favicon loader is `URLSession`, which sends CFNetwork's own
    /// User-Agent. Asking for "the last request" quietly answers about the
    /// wrong one.
    public func header(_ name: String, forPath path: String) -> String? {
        receivedRequests.first { $0.path == path }?.headers[name.lowercased()]
    }

    public private(set) var port: UInt16 = 0

    public init(routes: [Route] = []) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)

        for route in routes {
            self.routes[route.path] = route
        }
    }

    public var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    public func url(_ path: String) -> URL {
        baseURL.appending(path: path)
    }

    public func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: resumed.succeed()
                case .failed(let error): resumed.fail(error)
                default: break
                }
            }
            listener.start(queue: .global())
        }

        port = listener.port?.rawValue ?? 0
    }

    public func stop() {
        connections.forEach { $0.cancel() }
        connections.removeAll()
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .global())
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, isComplete, _ in
            guard let data, let request = String(data: data, encoding: .utf8) else {
                if isComplete { connection.cancel() }
                return
            }
            Task { await self?.respond(to: request, on: connection) }
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let path = Self.path(fromRequestLine: request)
        receivedRequests.insert((path, Self.headers(from: request)), at: 0)
        let route = routes[path]
        let body = route?.html ?? "<html><head><title>Not Found</title></head><body>404</body></html>"
        let status = route == nil ? "404 Not Found" : "200 OK"
        let contentType = route?.contentType ?? "text/html; charset=utf-8"

        let bytes = Array(body.utf8)
        let extra = (route?.extraHeaders ?? [:])
            .map { "\($0.key): \($0.value)\r\n" }
            .joined()

        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(bytes.count)\r
        \(extra)Connection: close\r
        \r
        \(body)
        """

        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    /// Everything after the request line, up to the blank line. Values may
    /// contain colons (a URL in a Referer, say), so only the first is a
    /// separator.
    private static func headers(from request: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in request.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return headers
    }

    private static func path(fromRequestLine request: String) -> String {
        guard let line = request.split(separator: "\r\n").first else { return "/" }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        return String(parts[1].split(separator: "?").first ?? "/")
    }
}

/// `stateUpdateHandler` can fire more than once; a continuation may only be
/// resumed once.
private final class ResumeOnce: @unchecked Sendable {
    private let continuation: CheckedContinuation<Void, any Error>
    private var done = false
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func succeed() {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume()
    }

    func fail(_ error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(throwing: error)
    }
}

public extension TestHTTPServer.Route {
    /// A page with a title, so `WKWebView.title` has something to report.
    static func page(path: String, title: String, body: String = "") -> Self {
        Self(
            path: path,
            html: """
            <!doctype html>
            <html><head><title>\(title)</title></head>
            <body>\(body)</body></html>
            """
        )
    }

    /// A page that sets a cookie on load — the basis of the isolation test.
    static func cookieSetter(path: String, title: String, cookie: String) -> Self {
        Self(
            path: path,
            html: """
            <!doctype html>
            <html><head><title>\(title)</title></head>
            <body><script>document.cookie = "\(cookie); path=/";</script></body></html>
            """
        )
    }

    /// Reports `document.cookie` through the page title.
    ///
    /// The title travels the ordinary snapshot pipeline, so a test can read it
    /// from the model — no JavaScript-evaluation hole has to be opened in the
    /// engine's public interface just to observe a page.
    static func cookieReporter(path: String) -> Self {
        Self(
            path: path,
            html: """
            <!doctype html>
            <html><head><title>loading</title></head>
            <body><script>
            document.title = "cookie:" + (document.cookie || "none");
            </script></body></html>
            """
        )
    }
}
