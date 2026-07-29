import Foundation
import Testing

@testable import BrowserCore

@Suite("User agent preference")
struct UserAgentTests {

    @Test("Default resolves to no override")
    func defaultIsNil() {
        #expect(UserAgentPreference.default.resolvedUserAgent == nil)
    }

    @Test("Presets resolve to plausible, distinct UA strings")
    func presetsResolve() {
        let chrome = UserAgentPreference.chrome.resolvedUserAgent
        let firefox = UserAgentPreference.firefox.resolvedUserAgent
        let iphone = UserAgentPreference.safariIPhone.resolvedUserAgent
        #expect(chrome?.contains("Chrome/") == true)
        #expect(firefox?.contains("Firefox/") == true)
        #expect(iphone?.contains("iPhone") == true)
        #expect(chrome != firefox && firefox != iphone)
    }

    @Test("A custom string resolves to itself, trimmed")
    func customResolves() {
        #expect(UserAgentPreference.custom("  MyAgent/1.0  ").resolvedUserAgent == "MyAgent/1.0")
    }

    @Test("An empty or whitespace custom string is treated as default")
    func emptyCustomIsNil() {
        #expect(UserAgentPreference.custom("").resolvedUserAgent == nil)
        #expect(UserAgentPreference.custom("   ").resolvedUserAgent == nil)
    }

    @Test("Round-trips through Codable")
    func codableRoundTrip() throws {
        for value: UserAgentPreference in [.default, .chrome, .custom("X/1")] {
            let data = try JSONEncoder().encode(value)
            let back = try JSONDecoder().decode(UserAgentPreference.self, from: data)
            #expect(back == value)
        }
    }
}
