import BrowserCore
import BrowserEngine
import Foundation

extension TabStore {

    /// Credentials offerable on the page a pane is showing, best first (V4).
    ///
    /// Metadata only — no secret is read here. Listing what exists and handing
    /// over a password are separate acts, and only the second one is privileged.
    /// Empty when the pane is not on an origin a credential may be filled into
    /// (non-https, no host — see `CredentialOrigin`).
    public func credentials(forPane paneID: UUID, inSpace spaceID: UUID?) async -> [Credential] {
        guard let vault,
            let url = runtime(for: paneID).currentURL,
            let origin = CredentialOrigin.canonical(for: url, policy: loginOriginPolicy)
        else { return [] }
        return (try? await vault.credentials(forOrigin: origin, spaceID: spaceID)) ?? []
    }

    /// Fills a saved credential into the page (V4).
    ///
    /// **Only ever called from a user gesture** (threat-model rule 4). Nothing
    /// here enforces that — a gesture is not something the store can observe —
    /// so it is a rule about call sites, and the reason there is no automatic
    /// caller anywhere in the app.
    ///
    /// The origin is checked twice on purpose: here, against the URL the pane
    /// reports, and again inside the engine against the live `WKWebView` at the
    /// moment of writing. The second one is the one that matters, because a page
    /// can navigate between the two.
    @discardableResult
    public func fillCredential(
        _ credentialID: UUID, intoPane paneID: UUID, inSpace spaceID: UUID?
    ) async -> LoginFillOutcome {
        guard let vault else { return .noPane }
        guard let form = runtime(for: paneID).loginForm, form.kind == .login else {
            return .fieldsUnavailable
        }
        guard let url = runtime(for: paneID).currentURL,
            let origin = CredentialOrigin.canonical(for: url, policy: loginOriginPolicy)
        else { return .originMismatch }

        // The credential must belong to the origin being shown. A mismatch here
        // means the caller offered something stale.
        guard let credential = (try? await vault.all())?.first(where: { $0.id == credentialID }),
            credential.origin == origin
        else { return .originMismatch }

        guard let secret = try? await vault.secret(for: credentialID, usedIn: spaceID) else {
            return .fieldsUnavailable
        }

        return await engine.fillLogin(
            paneID: paneID,
            expectedOrigin: origin,
            usernameFieldID: form.usernameFieldID,
            username: credential.username,
            passwordFieldID: form.passwordFieldID,
            password: secret
        )
    }
}
