import Foundation
import Testing
import WebKit

@testable import ChordEngine

/// The script behind `perf first-network-wait` (42j), against real WebKit with
/// a stand-in for the page's navigation timing.
@Suite("Startup network wait", .serialized)
@MainActor
struct StartupNetworkWaitTests {

    /// Runs the script with `performance` replaced by one reporting `entries`.
    private func wait(entries: String) async throws -> Int {
        let web = WKWebView(frame: .zero)
        let script = """
            (() => {
                const performance = { getEntriesByType: () => \(entries) };
                return \(WebKitEngine.networkWaitScript);
            })()
            """
        let value = try await web.evaluateJavaScript(script, contentWorld: .defaultClient)
        return try #require((value as? NSNumber)?.intValue)
    }

    @Test("Counts DNS, connection and the server's answer, and nothing else")
    func countsOnlyTheNetwork() async throws {
        // 100 ms before the lookup even starts (the launch's own stall), then
        // 20 ms DNS, 60 ms connecting, 400 ms for the server to answer.
        let entry = """
            [{ fetchStart: 0, domainLookupStart: 100, domainLookupEnd: 120,
               connectStart: 120, connectEnd: 180, requestStart: 181, responseStart: 581 }]
            """
        // The stall stays out: it is what the startup gate exists to judge.
        #expect(try await wait(entries: entry) == 480)
    }

    @Test("A reused connection counts only the server's answer")
    func reusedConnection() async throws {
        let entry = """
            [{ fetchStart: 5, domainLookupStart: 5, domainLookupEnd: 5,
               connectStart: 5, connectEnd: 5, requestStart: 6, responseStart: 306 }]
            """
        #expect(try await wait(entries: entry) == 300)
    }

    @Test("A page with no navigation timing reports nothing to take off")
    func noTiming() async throws {
        #expect(try await wait(entries: "[]") == -1)
        #expect(try await wait(entries: "[{ fetchStart: 0, responseStart: 0 }]") == -1)
    }
}
