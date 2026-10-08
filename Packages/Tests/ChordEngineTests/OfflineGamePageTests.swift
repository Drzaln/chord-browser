import Foundation
import Testing

@testable import ChordEngine

@Suite("Offline game page")
struct OfflineGamePageTests {

    @Test("The page URL round-trips the failed target")
    func targetRoundTrips() {
        let target = URL(string: "https://example.com/some/path?a=1&b=2")!
        let url = OfflineGamePage.url(target: target)
        #expect(url.scheme == OfflineGamePage.scheme)
        #expect(OfflineGamePage.targetURL(from: url) == target)
    }

    @Test("The page URL with no target carries no query")
    func noTarget() {
        let url = OfflineGamePage.url(target: nil)
        #expect(url.scheme == OfflineGamePage.scheme)
        #expect(OfflineGamePage.targetURL(from: url) == nil)
    }

    @Test("Only offline failures stand in for the game")
    func offlineClassification() {
        func error(_ code: Int) -> NSError {
            NSError(domain: NSURLErrorDomain, code: code)
        }
        #expect(OfflineGamePage.isOfflineError(error(NSURLErrorNotConnectedToInternet)))
        #expect(OfflineGamePage.isOfflineError(error(NSURLErrorNetworkConnectionLost)))
        #expect(!OfflineGamePage.isOfflineError(error(NSURLErrorTimedOut)))
        #expect(!OfflineGamePage.isOfflineError(error(NSURLErrorCannotFindHost)))
        #expect(!OfflineGamePage.isOfflineError(error(NSURLErrorCancelled)))
        #expect(!OfflineGamePage.isOfflineError(error(NSURLErrorDNSLookupFailed)))
        #expect(
            !OfflineGamePage.isOfflineError(
                NSError(domain: "WebKitErrorDomain", code: NSURLErrorNotConnectedToInternet)
            )
        )
    }

    @Test("The target is injected as a decodable JSON literal")
    func targetInjectionRoundTrips() throws {
        let target = URL(string: "https://example.com/a/b?x=1&y=2")!
        let html = OfflineGamePage.html(target: target)
        #expect(!html.contains("__TARGET__"))

        let prefix = "var TARGET = "
        let start = try #require(html.range(of: prefix))
        let rest = html[start.upperBound...]
        let end = try #require(rest.firstIndex(of: ";"))
        let literal = String(rest[..<end])
        #expect(try JSONDecoder().decode(String.self, from: Data(literal.utf8)) == target.absoluteString)
    }

    @Test("No target injects a null literal")
    func nullTarget() {
        let html = OfflineGamePage.html(target: nil)
        #expect(html.contains("var TARGET = null;"))
        #expect(!html.contains("__TARGET__"))
    }
}
