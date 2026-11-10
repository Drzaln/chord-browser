import Foundation
import Testing

@testable import ChordEngine

@Suite("Error page")
struct ErrorPageTests {
    private func error(_ code: Int, failing: String? = nil, domain: String = NSURLErrorDomain) -> NSError {
        var info: [String: Any] = [:]
        if let failing { info[NSURLErrorFailingURLErrorKey] = URL(string: failing)! }
        return NSError(domain: domain, code: code, userInfo: info)
    }

    @Test("The page URL round-trips the failed address and the code")
    func roundTrip() {
        let target = URL(string: "https://example.com/a/b?x=1&y=2#frag")!
        let url = ErrorPage.url(target: target, code: NSURLErrorTimedOut)
        #expect(ErrorPage.isErrorPage(url))
        #expect(ErrorPage.targetURL(from: url) == target)
        #expect(ErrorPage.code(from: url) == NSURLErrorTimedOut)
    }

    @Test("Retry can only ever go to an http(s) address")
    func targetIsWebOnly() {
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "chord-error://load-failed"] {
            var components = URLComponents()
            components.scheme = ErrorPage.scheme
            components.host = ErrorPage.host
            components.queryItems = [URLQueryItem(name: "url", value: bad)]
            #expect(ErrorPage.targetURL(from: components.url!) == nil, "\(bad)")
        }
        #expect(ErrorPage.targetURL(from: URL(string: "https://example.com/?url=https://a.b")!) == nil)
    }

    @Test("The failing URL comes from the error first, then the web view")
    func failedURL() {
        let previous = URL(string: "https://previous.example/")!
        let failing = error(NSURLErrorCannotFindHost, failing: "https://typo.example/")
        #expect(ErrorPage.failedURL(for: failing, webViewURL: previous)?.host() == "typo.example")
        #expect(ErrorPage.failedURL(for: error(NSURLErrorTimedOut), webViewURL: previous) == previous)
    }

    @Test("Cancelled loads, WebKit's own errors and non-web links get no page")
    func noPage() {
        let page = URL(string: "https://example.com/")!
        #expect(ErrorPage.failedURL(for: error(NSURLErrorCancelled), webViewURL: page) == nil)
        // 102: "Frame load interrupted", a navigation that became a download.
        #expect(ErrorPage.failedURL(for: error(102, domain: "WebKitErrorDomain"), webViewURL: page) == nil)
        #expect(ErrorPage.failedURL(for: error(1, domain: "WebKitInternal"), webViewURL: page) == nil)
        // A link to another app that nothing handles must leave the page alone.
        let external = error(NSURLErrorUnsupportedURL, failing: "zoommtg://join?x=1")
        #expect(ErrorPage.failedURL(for: external, webViewURL: page) == nil)
        #expect(ErrorPage.failedURL(for: error(NSURLErrorTimedOut), webViewURL: nil) == nil)
    }

    @Test("Each failure is worded as what it is")
    func kinds() {
        #expect(ErrorPage.kind(forCode: NSURLErrorCannotFindHost) == .cannotFindHost)
        #expect(ErrorPage.kind(forCode: NSURLErrorDNSLookupFailed) == .cannotFindHost)
        #expect(ErrorPage.kind(forCode: NSURLErrorCannotConnectToHost) == .cannotConnect)
        #expect(ErrorPage.kind(forCode: NSURLErrorTimedOut) == .timedOut)
        #expect(ErrorPage.kind(forCode: NSURLErrorHTTPTooManyRedirects) == .tooManyRedirects)
        for code in [
            NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
        ] {
            #expect(ErrorPage.kind(forCode: code) == .notSecure)
        }
        #expect(ErrorPage.kind(forCode: NSURLErrorBadServerResponse) == .other)
    }

    @Test("The page names the host, carries the code, and has no placeholder left")
    func html() {
        let target = URL(string: "https://example.com/path")!
        let html = ErrorPage.html(target: target, code: NSURLErrorCannotFindHost)
        #expect(html.contains("<title>example.com</title>"))
        #expect(html.contains("Chord can’t find example.com"))
        #expect(html.contains("NSURLErrorDomain \(NSURLErrorCannotFindHost)"))
        #expect(!html.contains("__"))
        // The retry target is a JSON literal the script can read back.
        #expect(html.contains(#"var TARGET = "https:\/\/example.com\/path";"#))
    }

    @Test("Nothing from the address can become markup or close the script")
    func escaping() {
        let hostile = URL(string: "https://example.com/?q=%3C/script%3E%3Cimg%20src=x%3E&a=%22")!
        let html = ErrorPage.html(target: hostile, code: NSURLErrorTimedOut)
        #expect(html.components(separatedBy: "</script>").count == 2)
        #expect(!html.contains("<img"))
        #expect(ErrorPage.escape(#"<a href="x">&"#) == "&lt;a href=&quot;x&quot;&gt;&amp;")
    }

    @Test("No address means no Retry target")
    func noTarget() {
        #expect(ErrorPage.html(target: nil, code: NSURLErrorUnknown).contains("var TARGET = null;"))
    }
}
