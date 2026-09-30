import Foundation
import Testing

@testable import ChordCore

/// `NativeLoginCapture` recovers a credential from WebKit's native form hook
/// (control `name` → value). It has no field *types* to work with, so every case
/// here is about judging by name alone — using the same real-site names the
/// `LoginFormClassifier` corpus uses, since the two paths must agree on what a
/// password field looks like.
@Suite("Native login capture")
struct NativeLoginCaptureTests {

    @Test("GitHub-style names: login + password")
    func githubStyle() {
        let credential = NativeLoginCapture.credential(
            from: ["login": "octocat", "password": "hunter2"]
        )
        #expect(credential == NativeLoginCapture.Credential(username: "octocat", password: "hunter2"))
    }

    @Test("Instagram-style names: email + pass")
    func instagramStyle() {
        let credential = NativeLoginCapture.credential(
            from: ["email": "me@example.com", "pass": "hunter2"]
        )
        #expect(
            credential == NativeLoginCapture.Credential(username: "me@example.com", password: "hunter2")
        )
    }

    @Test("A password-only step carries no username (Google's second page)")
    func passwordOnlyStep() {
        let credential = NativeLoginCapture.credential(from: ["password": "hunter2"])
        #expect(credential == NativeLoginCapture.Credential(username: "", password: "hunter2"))
    }

    @Test("A username-only step carries no password (Google's first page)")
    func usernameOnlyStep() {
        let credential = NativeLoginCapture.credential(from: ["identifier": "me@example.com"])
        #expect(credential == NativeLoginCapture.Credential(username: "me@example.com", password: ""))
    }

    @Test("Hidden fields a form submits are ignored: CSRF token, honeypots")
    func ignoresNonCredentialValues() {
        let credential = NativeLoginCapture.credential(
            from: [
                "authenticity_token": "abc123",
                "required_field_067": "bot-trap",
                "username": "octocat",
                "password": "hunter2",
            ]
        )
        #expect(credential == NativeLoginCapture.Credential(username: "octocat", password: "hunter2"))
    }

    @Test("A combined login_password field is a password, never a username")
    func combinedFieldIsPasswordOnly() {
        let credential = NativeLoginCapture.credential(from: ["login_password": "hunter2"])
        #expect(credential == NativeLoginCapture.Credential(username: "", password: "hunter2"))
    }

    @Test("A one-time code is never read as a password")
    func ignoresOneTimeCodes() {
        #expect(NativeLoginCapture.credential(from: ["otp": "123456"]) == nil)
        #expect(NativeLoginCapture.credential(from: ["one-time-code": "123456"]) == nil)
    }

    @Test("A non-login form reports nothing")
    func ignoresNonLoginForms() {
        #expect(NativeLoginCapture.credential(from: ["q": "swift concurrency"]) == nil)
        #expect(NativeLoginCapture.credential(from: ["search": "hello"]) == nil)
        #expect(NativeLoginCapture.credential(from: [:]) == nil)
    }

    @Test("Empty and non-string values are ignored")
    func ignoresEmptyAndNonStringValues() {
        let credential = NativeLoginCapture.credential(
            from: ["username": "octocat", "password": "", "pass": "hunter2", "tags": ["a", "b"]]
        )
        #expect(credential == NativeLoginCapture.Credential(username: "octocat", password: "hunter2"))
    }
}
