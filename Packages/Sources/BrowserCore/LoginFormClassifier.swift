import Foundation

/// What the page-side collector reports about one input. Plain values: the DOM
/// stays in the engine, the judgement happens here where it can be tested against
/// a corpus with no browser (V3 — `docs/design/password-vault.md`).
public struct LoginFieldDescriptor: Equatable, Sendable {
    /// A handle the collector can turn back into an element. Opaque here.
    public let elementID: String
    /// The `type` attribute, lowercased (`text`, `password`, `email`, `tel`…).
    public let type: String
    /// The raw `autocomplete` attribute. **Multi-token in the wild** — Instagram
    /// and Facebook both ship `username webauthn` — so it is tokenised, never
    /// compared whole.
    public let autocomplete: String
    public let name: String
    public let id: String
    public let placeholder: String
    public let label: String
    public let ariaLabel: String
    /// Whether the element is actually on screen and interactable.
    public let isVisible: Bool
    /// Document order, used only to break ties.
    public let index: Int

    public init(
        elementID: String, type: String, autocomplete: String = "", name: String = "",
        id: String = "", placeholder: String = "", label: String = "", ariaLabel: String = "",
        isVisible: Bool = true, index: Int = 0
    ) {
        self.elementID = elementID
        self.type = type.lowercased()
        self.autocomplete = autocomplete
        self.name = name
        self.id = id
        self.placeholder = placeholder
        self.label = label
        self.ariaLabel = ariaLabel
        self.isVisible = isVisible
        self.index = index
    }

    /// `autocomplete` split into its tokens, lowercased. The attribute is a
    /// space-separated list, and treating it as one string is the mistake that
    /// makes Instagram and Facebook undetectable.
    var autocompleteTokens: [String] {
        autocomplete.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Everything a human would read as naming this field, for keyword scoring.
    var descriptiveText: String {
        [name, id, placeholder, label, ariaLabel].joined(separator: " ").lowercased()
    }
}

/// What a page is asking for. Filling is only ever offered for `.login`.
public enum LoginFormKind: Equatable, Sendable {
    /// Username and password, or one step of a multi-step login.
    case login
    /// Creating an account or changing a password — `new-password` present. Never
    /// filled from the vault; this is the *capture* case, not the fill case.
    case newPassword
    /// Nothing here is a login.
    case none
}

/// The result of looking at one document's fields.
public struct LoginFormAnalysis: Equatable, Sendable {
    public let kind: LoginFormKind
    /// The field to put a username in, if any is on screen.
    public let usernameFieldID: String?
    /// The field to put a password in, if any is on screen.
    public let passwordFieldID: String?

    /// A login step showing only a username box (Google's first page) or only a
    /// password box (its second). Both are fillable; neither is a whole form.
    public var isMultiStep: Bool {
        kind == .login && (usernameFieldID == nil || passwordFieldID == nil)
    }

    public static let none = LoginFormAnalysis(
        kind: .none, usernameFieldID: nil, passwordFieldID: nil
    )
}

/// Decides which fields on a page are a login, from descriptors alone.
///
/// **Every rule here was derived from a captured corpus of real login pages**
/// (`LoginFormClassifierTests`), not from what the HTML spec wishes sites did:
///
/// - Google renders a **hidden decoy** password field on its username step.
/// - GitHub ships three invisible `required_field_*` **honeypots**; filling one
///   marks you a bot.
/// - Mixpanel's password field exists from the start but is invisible until the
///   email step passes.
/// - Instagram and Facebook use `autocomplete="username webauthn"`.
/// - npm sends **no `autocomplete` at all** — only `name` and a label.
/// - Reddit's fields live in **shadow DOM** (the collector's problem, not this
///   type's, but it is why the collector must pierce open shadow roots).
///
/// The first rule does most of the work: **invisible fields are ignored
/// entirely.** That single line handles the decoy, the honeypots, and the
/// not-yet-revealed field at once, and it is also §Threat-model rule 5.
public enum LoginFormClassifier {

    private static let usernameKeywords = [
        "username", "user", "email", "login", "identifier", "account", "phone",
    ]
    private static let passwordKeywords = ["password", "passwd", "pass"]
    /// Fields that look password-ish but must never receive one.
    private static let otpKeywords = ["otp", "one-time", "onetime", "code", "2fa", "totp"]

    public static func analyse(_ fields: [LoginFieldDescriptor]) -> LoginFormAnalysis {
        // Rule 5 of the threat model, and the single highest-value line in the
        // file: a field the user cannot see is never a field we touch.
        let visible = fields.filter(\.isVisible)
        guard !visible.isEmpty else { return .none }

        let passwordCandidates = visible.filter(isPasswordField)
        let usernameCandidates = visible.filter(isUsernameField)

        // A page asking for a *new* password is a signup or change-password form.
        // Those are for capturing a credential, never for filling one.
        let wantsNewPassword = passwordCandidates.contains {
            $0.autocompleteTokens.contains("new-password")
        }
        // Two visible password boxes is the other tell (password + confirm), and
        // it catches the forms that ship no autocomplete at all.
        let looksLikeConfirmation = passwordCandidates.count >= 2
        if wantsNewPassword || looksLikeConfirmation {
            return LoginFormAnalysis(
                kind: .newPassword,
                usernameFieldID: usernameCandidates.first?.elementID,
                passwordFieldID: passwordCandidates.first?.elementID
            )
        }

        let username = usernameCandidates.min { score(asUsername: $0) > score(asUsername: $1) }
        let password = passwordCandidates.first

        guard username != nil || password != nil else { return .none }
        return LoginFormAnalysis(
            kind: .login,
            usernameFieldID: username?.elementID,
            passwordFieldID: password?.elementID
        )
    }

    // MARK: - Field tests

    private static func isPasswordField(_ field: LoginFieldDescriptor) -> Bool {
        guard field.type == "password" else { return false }
        // A one-time code is sometimes rendered as a password box. It is not a
        // vault password, and filling it would be both wrong and confusing.
        if field.autocompleteTokens.contains("one-time-code") { return false }
        if otpKeywords.contains(where: field.descriptiveText.contains) { return false }
        return true
    }

    private static func isUsernameField(_ field: LoginFieldDescriptor) -> Bool {
        guard ["text", "email", "tel"].contains(field.type) else { return false }
        // An OTP box is often `type=text` with `one-time-code`; never a username.
        if field.autocompleteTokens.contains("one-time-code") { return false }
        if field.autocompleteTokens.contains("username")
            || field.autocompleteTokens.contains("email")
        {
            return true
        }
        if field.type == "email" { return true }
        // npm and friends ship no autocomplete at all: fall back to what the
        // field is called and what its label says.
        return usernameKeywords.contains(where: field.descriptiveText.contains)
    }

    /// Higher is a better username candidate. Explicit markup beats guessing, and
    /// document order breaks ties so the result is stable rather than arbitrary.
    private static func score(asUsername field: LoginFieldDescriptor) -> Int {
        var score = 0
        if field.autocompleteTokens.contains("username") { score += 100 }
        if field.autocompleteTokens.contains("email") { score += 80 }
        if field.type == "email" { score += 40 }
        if usernameKeywords.contains(where: field.descriptiveText.contains) { score += 20 }
        score -= field.index  // earlier fields win an otherwise exact tie
        return score
    }
}
