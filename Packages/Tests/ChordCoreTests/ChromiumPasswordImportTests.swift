import ChordCore
import Foundation
import Testing

/// The pure half of the Chromium import: browser detection and the rules that
/// decide what may become a Chord credential. No SQLite, no Keychain.
@Suite("Chromium password import plan")
struct ChromiumPasswordImportPlanTests {

    private func makeSource(
        browserID: String = "chrome", profile: String = "Default"
    ) throws -> ChromiumPasswordSource {
        let browser = try #require(
            ChromiumBrowser.known.first { $0.id == browserID }
        )
        return ChromiumPasswordSource(
            browser: browser, profileName: profile,
            databaseURL: URL(fileURLWithPath: "/tmp/Login Data")
        )
    }

    private func row(
        _ index: Int, realm: String, user: String = "alice",
        ciphertext: Data = Data([0x76, 0x31, 0x30, 0x01]),
        originURL: String = "", blacklisted: Bool = false
    ) -> ChromiumLoginRow {
        ChromiumLoginRow(
            rowIndex: index, signonRealm: realm, originURL: originURL,
            username: user, ciphertext: ciphertext, isBlacklisted: blacklisted
        )
    }

    // MARK: - Browser detection

    @Test("Chrome, a profile, and the exact file name are recognised")
    func detectChrome() throws {
        let source = try #require(
            ChromiumBrowser.detect(
                loginDataAt: URL(
                    fileURLWithPath:
                        "/Users/me/Library/Application Support/Google/Chrome/Profile 1/Login Data"
                )
            )
        )
        #expect(source.browser.id == "chrome")
        #expect(source.profileName == "Profile 1")
    }

    @Test("Chrome channels are not confused with each other")
    func detectChannels() throws {
        let beta = try #require(
            ChromiumBrowser.detect(
                loginDataAt: URL(
                    fileURLWithPath:
                        "/Users/me/Library/Application Support/Google/Chrome Beta/Default/Login Data"
                )
            )
        )
        #expect(beta.browser.id == "chrome-beta")
        #expect(beta.browser.keychainService == "Chrome Safe Storage")

        let arc = try #require(
            ChromiumBrowser.detect(
                loginDataAt: URL(
                    fileURLWithPath:
                        "/Users/me/Library/Application Support/Arc/User Data/Default/Login Data"
                )
            )
        )
        #expect(arc.browser.id == "arc")
        #expect(arc.profileName == "Default")
    }

    @Test("Opera's root-level profile is recognised")
    func detectOpera() throws {
        let source = try #require(
            ChromiumBrowser.detect(
                loginDataAt: URL(
                    fileURLWithPath:
                        "/Users/me/Library/Application Support/com.operasoftware.Opera/Login Data"
                )
            )
        )
        #expect(source.browser.id == "opera")
        #expect(source.profileName == "Opera")
    }

    @Test("An unknown profile layout is refused rather than guessed")
    func detectUnknown() {
        #expect(
            ChromiumBrowser.detect(
                loginDataAt: URL(
                    fileURLWithPath:
                        "/Users/me/Library/Application Support/Safari/Default/Login Data"
                )
            ) == nil
        )
        // The file name matters: a folder or a similarly named file is not one.
        #expect(
            ChromiumBrowser.detect(
                loginDataAt: URL(
                    fileURLWithPath:
                        "/Users/me/Library/Application Support/Google/Chrome/Default/Login Data 2"
                )
            ) == nil
        )
    }

    // MARK: - Origins

    @Test("Origins use the vault's canonical scheme+host+port form")
    func canonicalOrigins() throws {
        let source = try makeSource()
        let plan = ChromiumPasswordPlanner.plan(
            source: source,
            rows: [
                row(0, realm: "https://Example.COM:443/login", user: "alice"),
                row(1, realm: "https://example.com:8443/", user: "bob"),
                row(2, realm: "https://example.com./", user: "carol"),
                row(3, realm: "https://93.184.216.34:8443/", user: "dave"),
            ]
        )
        #expect(plan.candidates.map(\.origin) == [
            "https://example.com",
            "https://example.com:8443",
            "https://example.com",
            "https://93.184.216.34:8443",
        ])
        #expect(plan.skipped.isEmpty)
    }

    @Test("http, file, javascript, extension, and Android origins are refused")
    func refusedSchemes() throws {
        let source = try makeSource()
        let plan = ChromiumPasswordPlanner.plan(
            source: source,
            rows: [
                row(0, realm: "http://example.com/"),
                row(1, realm: "http://localhost:3000/"),
                row(2, realm: "file:///etc/passwd"),
                row(3, realm: "javascript:alert(1)"),
                row(4, realm: "chrome-extension://abcdefghijklmnop/"),
                row(5, realm: "android://hash@com.example.app/"),
            ]
        )
        #expect(plan.candidates.isEmpty)
        #expect(plan.count(for: .insecureOrigin) == 2)
        #expect(plan.count(for: .unsupportedScheme) == 4)
        #expect(plan.skippedCount == 6)
    }

    @Test("An address with embedded credentials is refused, not quietly stripped")
    func embeddedCredentials() throws {
        let source = try makeSource()
        let plan = ChromiumPasswordPlanner.plan(
            source: source,
            rows: [
                row(0, realm: "https://user:pass@example.net/"),
                row(1, realm: "https://user@example.net/"),
                row(2, realm: "https://93.184.216.34@evil.example/"),
            ]
        )
        #expect(plan.candidates.isEmpty)
        #expect(plan.count(for: .embeddedCredentials) == 3)
    }

    @Test("An empty realm falls back to the page URL; a broken realm does not")
    func realmFallback() throws {
        let source = try makeSource()
        let plan = ChromiumPasswordPlanner.plan(
            source: source,
            rows: [
                row(0, realm: "", originURL: "https://fallback.example/login"),
                row(1, realm: "not a url", originURL: "https://fallback.example/login"),
                row(2, realm: "https://", originURL: "https://fallback.example/login"),
            ]
        )
        #expect(plan.candidates.map(\.origin) == ["https://fallback.example"])
        #expect(plan.count(for: .invalidOrigin) == 2)
    }

    // MARK: - Rows

    @Test("Empty usernames, blacklist rows, duplicates, and known logins are reported")
    func refusedRows() throws {
        let source = try makeSource()
        let existing = Set([
            ChromiumPasswordIdentity(origin: "https://known.example", username: "me")
        ])
        let plan = ChromiumPasswordPlanner.plan(
            source: source,
            rows: [
                row(0, realm: "https://example.com/", user: "alice"),
                row(1, realm: "https://example.com/", user: "alice"),
                row(2, realm: "https://example.com/", user: "  "),
                row(3, realm: "https://example.com/", user: "bob", blacklisted: true),
                row(4, realm: "https://known.example/", user: "me"),
            ],
            existing: existing
        )
        #expect(plan.candidates.count == 1)
        #expect(plan.count(for: .duplicateLogin) == 1)
        #expect(plan.count(for: .emptyUsername) == 1)
        #expect(plan.count(for: .blacklisted) == 1)
        #expect(plan.alreadyPresentCount == 1)
        #expect(plan.skippedCount == 3)
    }

    @Test("A username without a password stays a candidate with no ciphertext")
    func usernameOnly() throws {
        let source = try makeSource()
        let plan = ChromiumPasswordPlanner.plan(
            source: source,
            rows: [row(0, realm: "https://example.com/", user: "alice", ciphertext: Data())]
        )
        #expect(plan.importCount == 1)
        #expect(plan.candidates.first?.ciphertext.isEmpty == true)
        #expect(plan.skipped.isEmpty)
    }

    @Test("The username is stored exactly as another browser wrote it")
    func usernamePreserved() throws {
        let source = try makeSource()
        let plan = ChromiumPasswordPlanner.plan(
            source: source,
            rows: [row(0, realm: "https://example.com/", user: " Alice ")]
        )
        #expect(plan.candidates.first?.username == " Alice ")
    }

    @Test("A profile outside a known layout can be named explicitly")
    func explicitBrowser() throws {
        let url = URL(
            fileURLWithPath: "/tmp/chord-passwords-smoke/Default/Login Data"
        )
        #expect(ChromiumBrowser.detect(loginDataAt: url) == nil)
        let chrome = try #require(
            ChromiumBrowser.known.first { $0.id == "chrome" }
        )
        let source = try #require(
            ChromiumPasswordSource(loginDataAt: url, browser: chrome)
        )
        #expect(source.browser.id == "chrome")
        #expect(source.profileName == "Default")
        #expect(
            ChromiumPasswordSource(
                loginDataAt: URL(fileURLWithPath: "/tmp/chord-passwords-smoke/Login Data 2"),
                browser: chrome
            ) == nil
        )
    }

    @Test("Two accounts on the same origin are both imported")
    func multipleAccounts() throws {
        let source = try makeSource()
        let plan = ChromiumPasswordPlanner.plan(
            source: source,
            rows: [
                row(0, realm: "https://example.com/", user: "work@example.com"),
                row(1, realm: "https://example.com/", user: "personal@example.com"),
            ]
        )
        #expect(plan.candidates.count == 2)
        #expect(plan.candidates.map(\.origin) == [
            "https://example.com", "https://example.com",
        ])
        #expect(plan.skipped.isEmpty)
    }
}
