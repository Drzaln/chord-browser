import Foundation
import Testing

@testable import BrowserCore

/// The corpus is **captured, not invented**: each fixture below is what a real
/// `WKWebView` reported after loading that site's live login page on 2026-07-31
/// (probe in the V3 spike). Every rule in `LoginFormClassifier` exists because
/// one of these sites does something a spec-reading implementation would get
/// wrong.
///
/// When a site changes its markup, re-capture rather than hand-edit — a fixture
/// that no longer matches reality is worse than no fixture, because it makes a
/// broken classifier look tested.
@Suite("Login form classifier")
struct LoginFormClassifierTests {

    // MARK: - Captured corpus

    /// Google's first step: username visible, plus an **invisible decoy password
    /// field** (`hiddenPassword`). Filling the decoy would put the password in a
    /// field the user cannot see, on the page before the real one.
    private let google = [
        LoginFieldDescriptor(
            elementID: "g1", type: "text", autocomplete: "username", name: "identifier",
            id: "identifierId", label: "Email or phone", isVisible: true, index: 0
        ),
        LoginFieldDescriptor(
            elementID: "g2", type: "password", name: "hiddenPassword",
            isVisible: false, index: 1
        ),
    ]

    /// Instagram and Facebook: `autocomplete="username webauthn"` — the token list
    /// that breaks any `autocomplete == "username"` comparison.
    private let instagram = [
        LoginFieldDescriptor(
            elementID: "i1", type: "text", autocomplete: "username webauthn", name: "email",
            label: "Mobile number, username or email address", isVisible: true, index: 0
        ),
        LoginFieldDescriptor(
            elementID: "i2", type: "password", name: "pass", label: "Password",
            isVisible: true, index: 1
        ),
    ]

    /// GitHub: a real login plus three invisible `required_field_*` honeypots.
    /// Filling one is how a password manager gets its user flagged as a bot.
    private let github = [
        LoginFieldDescriptor(
            elementID: "h1", type: "text", autocomplete: "username", name: "login",
            label: "Username or email address", isVisible: true, index: 0
        ),
        LoginFieldDescriptor(
            elementID: "h2", type: "password", autocomplete: "current-password",
            name: "password", label: "Password", isVisible: true, index: 1
        ),
        LoginFieldDescriptor(
            elementID: "h3", type: "text", name: "required_field_067", isVisible: false, index: 2
        ),
        LoginFieldDescriptor(
            elementID: "h4", type: "text", name: "required_field_66e", isVisible: false, index: 3
        ),
        LoginFieldDescriptor(
            elementID: "h5", type: "text", name: "required_field_7ae", isVisible: false, index: 4
        ),
    ]

    /// Mixpanel: the password field exists in the DOM from the start but is
    /// invisible until the email step passes — progressive disclosure, not a trap,
    /// and handled by the same visibility rule.
    private let mixpanel = [
        LoginFieldDescriptor(
            elementID: "m1", type: "email", autocomplete: "username", name: "emailInput",
            placeholder: "e.g. eleanor@mixpanel.com", isVisible: true, index: 0
        ),
        LoginFieldDescriptor(
            elementID: "m2", type: "password", autocomplete: "current-password",
            name: "passwordInput", isVisible: false, index: 1
        ),
    ]

    /// npm: **no `autocomplete` attributes at all.** Only `name` and the label say
    /// what these are, which is why keyword fallback has to exist.
    private let npm = [
        LoginFieldDescriptor(
            elementID: "n1", type: "text", name: "username", label: "Username",
            isVisible: true, index: 0
        ),
        LoginFieldDescriptor(
            elementID: "n2", type: "password", name: "password", label: "Password",
            isVisible: true, index: 1
        ),
    ]

    /// Reddit: a normal-looking login *inside shadow DOM* (the collector's
    /// problem), carrying two hidden one-time-code fields that must never be
    /// treated as a username or a password.
    private let reddit = [
        LoginFieldDescriptor(
            elementID: "r1", type: "text", autocomplete: "username webauthn", name: "username",
            isVisible: true, index: 0
        ),
        LoginFieldDescriptor(
            elementID: "r2", type: "password", autocomplete: "current-password",
            name: "password", isVisible: true, index: 1
        ),
        LoginFieldDescriptor(
            elementID: "r3", type: "tel", autocomplete: "one-time-code", name: "appOtp",
            isVisible: false, index: 2
        ),
        LoginFieldDescriptor(
            elementID: "r4", type: "text", autocomplete: "one-time-code", name: "backupOtp",
            isVisible: false, index: 3
        ),
    ]

    // MARK: - The corpus must classify correctly

    @Test("Instagram: multi-token autocomplete is understood")
    func instagramIsALogin() {
        let result = LoginFormClassifier.analyse(instagram)
        #expect(result.kind == .login)
        #expect(result.usernameFieldID == "i1")
        #expect(result.passwordFieldID == "i2")
    }

    /// Isolates the tokenising rule. The Instagram fixture above does *not* prove
    /// it: that field is also called `email`, so keyword fallback rescues it even
    /// with the attribute compared as one string. Here `autocomplete` is the only
    /// signal there is, which is what makes this test fail against the naive
    /// comparison — checked by breaking it deliberately.
    @Test("Multi-token autocomplete alone identifies a username")
    func multiTokenAutocompleteAlone() {
        let result = LoginFormClassifier.analyse([
            LoginFieldDescriptor(
                elementID: "t1", type: "text", autocomplete: "username webauthn",
                isVisible: true, index: 0
            ),
            LoginFieldDescriptor(
                elementID: "t2", type: "password", autocomplete: "current-password",
                isVisible: true, index: 1
            ),
        ])
        #expect(result.usernameFieldID == "t1")
        #expect(result.passwordFieldID == "t2")
    }

    @Test("npm: no autocomplete anywhere still classifies from names and labels")
    func npmIsALogin() {
        let result = LoginFormClassifier.analyse(npm)
        #expect(result.usernameFieldID == "n1")
        #expect(result.passwordFieldID == "n2")
    }

    @Test("GitHub: the three honeypots are never chosen")
    func githubIgnoresHoneypots() {
        let result = LoginFormClassifier.analyse(github)
        #expect(result.usernameFieldID == "h1")
        #expect(result.passwordFieldID == "h2")
        // The bot-trap fields must not appear as either target.
        #expect(["h3", "h4", "h5"].contains(result.usernameFieldID ?? "") == false)
    }

    @Test("Google: the hidden decoy password field is not a fill target")
    func googleIgnoresDecoy() {
        let result = LoginFormClassifier.analyse(google)
        #expect(result.kind == .login)
        #expect(result.usernameFieldID == "g1")
        #expect(result.passwordFieldID == nil, "hiddenPassword must never be filled")
        #expect(result.isMultiStep, "a username-only step is still fillable")
    }

    @Test("Mixpanel: a not-yet-revealed password field is left alone for now")
    func mixpanelIsUsernameStep() {
        let result = LoginFormClassifier.analyse(mixpanel)
        #expect(result.usernameFieldID == "m1")
        #expect(result.passwordFieldID == nil)
        #expect(result.isMultiStep)
    }

    @Test("Reddit: one-time-code fields are neither username nor password")
    func redditIgnoresOTP() {
        let result = LoginFormClassifier.analyse(reddit)
        #expect(result.usernameFieldID == "r1")
        #expect(result.passwordFieldID == "r2")
    }

    // MARK: - The second step of a multi-step login

    @Test("A password-only step is fillable")
    func passwordOnlyStep() {
        let result = LoginFormClassifier.analyse([
            LoginFieldDescriptor(
                elementID: "p1", type: "password", autocomplete: "current-password",
                name: "password", isVisible: true, index: 0
            )
        ])
        #expect(result.kind == .login)
        #expect(result.usernameFieldID == nil)
        #expect(result.passwordFieldID == "p1")
        #expect(result.isMultiStep)
    }

    // MARK: - Forms that must never be filled from the vault

    @Test("A signup form is not a login")
    func signupIsNotLogin() {
        let result = LoginFormClassifier.analyse([
            LoginFieldDescriptor(
                elementID: "s1", type: "email", autocomplete: "username", isVisible: true, index: 0
            ),
            LoginFieldDescriptor(
                elementID: "s2", type: "password", autocomplete: "new-password",
                isVisible: true, index: 1
            ),
        ])
        #expect(result.kind == .newPassword)
    }

    @Test("Password plus confirm is a new password, even with no autocomplete")
    func confirmationPairIsNewPassword() {
        let result = LoginFormClassifier.analyse([
            LoginFieldDescriptor(
                elementID: "c1", type: "password", name: "password", label: "New password",
                isVisible: true, index: 0
            ),
            LoginFieldDescriptor(
                elementID: "c2", type: "password", name: "confirm", label: "Confirm password",
                isVisible: true, index: 1
            ),
        ])
        #expect(result.kind == .newPassword)
    }

    @Test("A search box is not a login")
    func searchIsNotLogin() {
        let result = LoginFormClassifier.analyse([
            LoginFieldDescriptor(
                elementID: "q", type: "text", name: "q", placeholder: "Search",
                isVisible: true, index: 0
            )
        ])
        #expect(result.kind == .none)
    }

    @Test("A page with nothing visible is nothing at all")
    func allHiddenIsNone() {
        let result = LoginFormClassifier.analyse([
            LoginFieldDescriptor(
                elementID: "x", type: "password", name: "password", isVisible: false, index: 0
            )
        ])
        #expect(result == .none)
    }

    @Test("An OTP box rendered as a password field is not a password field")
    func otpAsPasswordIsRejected() {
        let result = LoginFormClassifier.analyse([
            LoginFieldDescriptor(
                elementID: "o1", type: "password", name: "otp", label: "One-time code",
                isVisible: true, index: 0
            )
        ])
        #expect(result.passwordFieldID == nil)
    }
}
