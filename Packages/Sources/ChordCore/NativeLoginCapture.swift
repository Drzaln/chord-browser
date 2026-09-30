import Foundation

/// Recovers a submitted credential from WebKit's native form-submission callback
/// (`_WKInputDelegate._webView(_:willSubmitFormValues:…)`).
///
/// The page-side `PasswordFormMonitor` cannot see a form inside a **closed**
/// shadow root — `element.shadowRoot` is null there by design — so a site that
/// renders its login that way is invisible to the script and never captured.
/// WebKit's own hook reports the submitted values (control name → value) no
/// matter where the form lives, which is the whole reason this exists.
///
/// What it does **not** have is field *types*: the values are a flat dictionary
/// keyed by each control's `name`. So the password is the value whose name reads
/// like a password, the username the value whose name reads like one, and
/// nothing is reported when neither can be told — the same "never guess a wrong
/// target" stance as `LoginFormClassifier`, whose keyword lists it shares.
///
/// Pure and WebKit-free, so the judgement is tested against the same real-site
/// names the classifier corpus uses, with no web view.
public enum NativeLoginCapture {

    /// What a native form submission carried. `username` is empty on a
    /// password-only step (Google's second page); the store pairs it with the
    /// username it remembered from the earlier step, exactly as it does for the
    /// page-side path. The password is the one value in the app that must never
    /// be logged — same rule as the page-side capture.
    public struct Credential: Equatable, Sendable {
        public let username: String
        public let password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    /// The credential a submitted form carried, or nil when the values do not
    /// read as a login at all.
    ///
    /// Non-string values (a multi-select's array, a file input) are dropped, and
    /// keys are walked in sorted order so the answer is deterministic —
    /// `Dictionary` order is not.
    public static func credential(from formValues: [String: Any]) -> Credential? {
        let named =
            formValues
            .compactMap { key, value -> (String, String)? in
                guard let text = value as? String, !text.isEmpty else { return nil }
                return (key, text)
            }
            .sorted { $0.0 < $1.0 }

        func matches(_ key: String, _ keywords: [String]) -> Bool {
            let lower = key.lowercased()
            return keywords.contains(where: lower.contains)
        }
        func isOneTimeCode(_ key: String) -> Bool {
            matches(key, LoginFormClassifier.otpKeywords)
        }

        // A password is only ever the value whose name says so. The alternative
        // — "the field that is not the username" — is how a CSRF token or a
        // submit button's value ends up saved as a password.
        let password = named.first {
            matches($0.0, LoginFormClassifier.passwordKeywords) && !isOneTimeCode($0.0)
        }?.1

        // The username is a name that reads like one and is not the password
        // (a combined `login_password` field must not be read as both).
        let username = named.first {
            matches($0.0, LoginFormClassifier.usernameKeywords)
                && !matches($0.0, LoginFormClassifier.passwordKeywords)
                && !isOneTimeCode($0.0)
        }?.1

        guard password != nil || username != nil else { return nil }
        return Credential(username: username ?? "", password: password ?? "")
    }
}
