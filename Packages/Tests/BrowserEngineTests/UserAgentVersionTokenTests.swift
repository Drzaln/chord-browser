import BrowserCore
import Foundation
import Testing

@testable import BrowserEngine

/// The engine's UA suffix must be the shared token, not a copy of it. A second
/// literal in the engine is exactly the drift the token exists to prevent.
@Suite("User-Agent version token")
@MainActor
struct UserAgentVersionTokenTests {

    @Test("The engine suffix is the BrowserCore token, verbatim")
    func engineSuffixMatchesCoreToken() {
        #expect(WebKitEngine.safariUserAgentSuffix == UserAgentPreference.safariVersionToken)
    }
}
