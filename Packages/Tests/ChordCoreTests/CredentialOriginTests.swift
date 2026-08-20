import Foundation
import Testing

@testable import ChordCore

/// The rule that decides every fill. A false positive here hands a password to
/// the wrong site, so the near-miss table is deliberately longer than the
/// happy-path one.
@Suite("Credential origin matching")
struct CredentialOriginTests {

    // MARK: - Canonicalisation

    @Test("An https URL reduces to scheme and host")
    func canonicalStripsPathAndQuery() {
        #expect(
            CredentialOrigin.canonical(for: URL(string: "https://example.com/login?next=/a#x")!)
                == "https://example.com"
        )
    }

    @Test("Scheme and host are lowercased")
    func canonicalLowercases() {
        #expect(
            CredentialOrigin.canonical(for: URL(string: "HTTPS://Example.COM/")!)
                == "https://example.com"
        )
    }

    @Test("The default port is dropped, a non-default port is kept")
    func canonicalHandlesPorts() {
        #expect(
            CredentialOrigin.canonical(for: URL(string: "https://example.com:443/")!)
                == "https://example.com"
        )
        #expect(
            CredentialOrigin.canonical(for: URL(string: "https://example.com:8443/")!)
                == "https://example.com:8443"
        )
    }

    @Test("A fully-qualified trailing dot is the same host, not a second entry")
    func canonicalDropsTrailingDot() {
        #expect(
            CredentialOrigin.canonical(for: URL(string: "https://example.com./")!)
                == "https://example.com"
        )
    }

    @Test("Embedded credentials never survive into the origin")
    func canonicalDropsUserInfo() {
        let origin = CredentialOrigin.canonical(for: URL(string: "https://user:pw@example.com/")!)
        #expect(origin == "https://example.com")
    }

    @Test(
        "Anything that is not https has no origin",
        arguments: [
            "http://example.com/",
            "http://localhost:3000/",
            "file:///Users/me/login.html",
            "data:text/html,<form>",
            "about:blank",
            "javascript:alert(1)",
            "ftp://example.com/",
        ]
    )
    func canonicalRejectsNonHTTPS(_ raw: String) {
        #expect(CredentialOrigin.canonical(for: URL(string: raw)!) == nil)
    }

    // MARK: - Matching

    @Test("The same origin matches, with any path")
    func matchesSameOrigin() {
        #expect(
            CredentialOrigin.matches(
                stored: "https://example.com",
                candidate: URL(string: "https://example.com/account/settings")!
            )
        )
    }

    /// Each of these has been a real credential-theft vector in some manager.
    @Test(
        "Near misses never match",
        arguments: [
            "https://evil.example.com/",       // subdomain
            "https://example.com.evil.com/",   // suffix attack
            "https://examp1e.com/",            // homograph-ish
            "https://example.co/",             // truncated TLD
            "https://sub.example.com/",        // any subdomain, benign or not
            "http://example.com/",             // downgraded scheme
            "https://example.com:8443/",       // different port
            "https://xn--exmple-cua.com/",     // punycode look-alike
        ]
    )
    func rejectsNearMisses(_ raw: String) {
        #expect(
            CredentialOrigin.matches(
                stored: "https://example.com", candidate: URL(string: raw)!
            ) == false
        )
    }

    @Test("A credential saved on a subdomain does not leak to the parent")
    func subdomainDoesNotLeakUpwards() {
        #expect(
            CredentialOrigin.matches(
                stored: "https://mail.example.com",
                candidate: URL(string: "https://example.com/")!
            ) == false
        )
    }

    // MARK: - The loopback opt-in

    /// The e2e suite serves plain HTTP from loopback, so the vault has an opt-in
    /// for it. These tests exist to keep that opt-in from becoming the default
    /// by accident — which would make every `http://` page fillable.
    @Test("The default policy is strict")
    func defaultIsStrict() {
        #expect(CredentialOrigin.Policy.strict.allowsInsecureLoopback == false)
        #expect(CredentialOrigin.Policy().allowsInsecureLoopback == false)
        // The default argument, which is what every production call site uses.
        #expect(CredentialOrigin.canonical(for: URL(string: "http://127.0.0.1:8080/")!) == nil)
    }

    @Test("The opt-in allows loopback HTTP and nothing else")
    func loopbackOptInIsNarrow() {
        let policy = CredentialOrigin.Policy.allowingInsecureLoopback
        #expect(
            CredentialOrigin.canonical(for: URL(string: "http://127.0.0.1:8080/")!, policy: policy)
                == "http://127.0.0.1:8080"
        )
        #expect(
            CredentialOrigin.canonical(for: URL(string: "http://localhost/")!, policy: policy)
                == "http://localhost"
        )
        // Still not a licence for plain HTTP anywhere else.
        #expect(
            CredentialOrigin.canonical(for: URL(string: "http://example.com/")!, policy: policy)
                == nil
        )
        // Nor for a host that merely looks local.
        #expect(
            CredentialOrigin.canonical(
                for: URL(string: "http://localhost.evil.com/")!, policy: policy
            ) == nil
        )
    }

    @Test("A non-fillable URL matches nothing, even an identical-looking store")
    func unfillableCandidateNeverMatches() {
        #expect(
            CredentialOrigin.matches(
                stored: "https://example.com", candidate: URL(string: "http://example.com/")!
            ) == false
        )
    }
}
