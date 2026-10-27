import Testing
import WebKit

@testable import ChordEngine

@MainActor
struct ChromeWebStoreRelayTests {
    @Test func scriptOnlyRunsOnTheStore() {
        let script = ChromeWebStoreRelay.makeUserScript()
        #expect(script.injectionTime == .atDocumentEnd)
        #expect(script.isForMainFrameOnly)
        #expect(script.source.contains("chromewebstore.google.com"))
        #expect(script.source.contains("Use Add to Chord above"))
        #expect(script.source.contains("__chordStore"))
    }
}
