import ChordCore
import Foundation
import Testing

@testable import ChordEngine

/// The engine's UA suffix must be the shared token, not a copy of it. A second
/// literal in the engine is exactly the drift the token exists to prevent.
@Suite("User-Agent version token")
@MainActor
struct UserAgentVersionTokenTests {

    @Test("The engine suffix is the ChordCore token, verbatim")
    func engineSuffixMatchesCoreToken() {
        #expect(WebKitEngine.safariUserAgentSuffix == UserAgentPreference.safariVersionToken)
    }
}
