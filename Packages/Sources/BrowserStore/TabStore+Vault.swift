import BrowserCore
import BrowserEngine
import Foundation

extension TabStore {

    // MARK: - Capture (V5)

    /// A page submitted a login. Decide whether to offer to save it.
    ///
    /// Says nothing, on purpose, in three cases: the site is silenced
    /// (`credentialNeverSave`), there is no vault, or the exact same password is
    /// already stored for that login. The last one is what stops the bar
    /// appearing every single time you sign in to a site you already saved.
    func handleSubmittedLogin(
        origin: String, username: String, password: String, paneID: UUID
    ) async {
        guard let vault, !password.isEmpty else { return }
        guard (try? await vault.isNeverSave(origin: origin)) != true else { return }

        let existing = (try? await vault.credentials(forOrigin: origin, spaceID: nil)) ?? []
        let match = existing.first { $0.username == username }
        if let match, (try? vault.storedSecret(for: match.id)) == password {
            return  // already saved, unchanged: nothing to ask about
        }

        // Collapse a repeat of the same offer — the page-side capture fires on
        // submit *and* on a plausible submit click, so one sign-in can report
        // twice.
        if let pending = pendingCredentialSave,
            pending.origin == origin, pending.username == username,
            pendingCredentialSecrets[pending.id] == password
        {
            return
        }

        let prompt = CredentialSavePrompt(
            origin: origin,
            host: URL(string: origin)?.host ?? origin,
            username: username,
            isUpdate: match != nil
        )
        pendingCredentialSecrets[prompt.id] = password
        // The Space the login happened in, captured now: the user may switch
        // Space before answering, and the "last used here" hint should record
        // where they actually signed in.
        pendingCredentialSpaces[prompt.id] = spaceID(forPane: paneID)
        pendingCredentialSave = prompt
    }

    /// Answers the save bar.
    ///
    /// The secret is dropped from the side table in every branch, including the
    /// ones that do not save — a declined password must not sit in memory
    /// waiting for the next prompt.
    public func resolveCredentialSave(_ decision: CredentialSaveDecision) async {
        guard let prompt = pendingCredentialSave else { return }
        let secret = pendingCredentialSecrets.removeValue(forKey: prompt.id)
        let spaceID = pendingCredentialSpaces.removeValue(forKey: prompt.id) ?? nil
        pendingCredentialSave = nil

        switch decision {
        case .dismiss:
            return
        case .never:
            try? await vault?.setNeverSave(origin: prompt.origin)
        case .save:
            guard let secret, let vault else { return }
            _ = try? await vault.save(
                origin: prompt.origin, username: prompt.username, secret: secret,
                spaceID: spaceID
            )
        }
    }

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
