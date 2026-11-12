import Foundation

/// When the first-run welcome is offered (gn0.6).
///
/// Once per profile, and only to a profile that had nothing in it: someone who
/// already has Spaces and tabs is not new, whatever the flag says. That second
/// half is what keeps the sheet away from every profile that existed before
/// this feature did.
public enum WelcomePolicy {
    public static func shouldShow(alreadyShown: Bool, isFreshProfile: Bool) -> Bool {
        !alreadyShown && isFreshProfile
    }
}

extension TabStore {
    /// Decides the welcome at the end of `restore()`, and settles the flag so
    /// the question is never asked twice. Marked shown when it is *offered*,
    /// not when it is dismissed: quitting with the sheet up must not bring it
    /// back.
    func offerWelcomeIfFirstRun(isFreshProfile: Bool) {
        let alreadyShown = Preferences.loadWelcomeShown(preferenceStore)
        if WelcomePolicy.shouldShow(alreadyShown: alreadyShown, isFreshProfile: isFreshProfile) {
            primaryWindow.isWelcomePresented = true
        }
        if !alreadyShown {
            Preferences.save(welcomeShown: true, to: preferenceStore)
        }
    }
}
