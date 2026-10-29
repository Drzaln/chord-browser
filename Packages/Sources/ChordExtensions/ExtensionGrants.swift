import Foundation
import WebKit

/// What a context is given as it loads, beyond its declared API permissions,
/// and what it is never given. Ported from Search's `Extensions.load`,
/// `fence` and `withheld`, minus `grantSites`: Search's install dialog is the
/// consent for an extension's sites, and Chord asks for host access instead
/// (BROWSER_SPEC 7.5c) until install consent (1mm.6.5) exists.
@MainActor
enum ExtensionGrants {
    private static let extensionSchemes = ["chrome-extension", "webkit-extension"]

    /// Load-time grants, after the declared permissions.
    static func applyAtLoad(to context: WKWebExtensionContext, identifier: String) {
        let requested = context.webExtension.requestedPermissions
        // Chrome lets "declarativeNetRequest" redirect or change headers on
        // the sites the extension has access to. WebKit does that only with
        // "declarativeNetRequestWithHostAccess", and otherwise drops those
        // rules without a word: in Search, Norma's redirect of a blocked site
        // to its own page never happened. WebKit still holds the rules to the
        // sites granted, so this widens nothing.
        if requested.contains(.declarativeNetRequest) {
            context.setPermissionStatus(
                .grantedExplicitly, for: .declarativeNetRequestWithHostAccess
            )
        }
        // Its own sign-in address, https://<id>.chromiumapp.org, which is
        // never loaded (ExtensionAuthWindow catches it). WebKit shows an
        // extension a tab's address only where it has access, where Chrome's
        // "tabs" is enough, and one watching its sign-in tab for that address
        // has to be able to see it. WebKit doesn't know "identity", so the
        // manifest is read directly.
        let declared = context.webExtension.manifest["permissions"] as? [String] ?? []
        if declared.contains("identity"),
            let own = try? WKWebExtension.MatchPattern(
                string: "https://\(identifier.lowercased()).chromiumapp.org/*"
            )
        {
            context.setPermissionStatus(.grantedExplicitly, for: own)
        }
        fence(context)
    }

    /// Extension pages (another extension's, or every one's) and files on this
    /// Mac: no extension is given them, from its manifest or asked for later.
    /// Its own pages are its own without asking. Chrome keeps files from every
    /// extension until "Allow access to file URLs", and Chord has no such
    /// switch.
    static func withheld(_ pattern: WKWebExtension.MatchPattern) -> Bool {
        guard let scheme = pattern.scheme?.lowercased() else { return false }
        return extensionSchemes.contains(scheme) || scheme == "file"
    }

    /// Refuses extension pages and files outright. With chrome-extension
    /// registered as a scheme, WebKit counts other extensions' pages in
    /// <all_urls>, which Chrome doesn't. Run again after anything is granted.
    ///
    /// WebKit takes back any grant that a refusal covers, so refusing
    /// extension pages wipes a grant of <all_urls> the moment it is made (in
    /// Search, permissions.request said yes, contains() said no, and Figma's
    /// extension waited forever). What <all_urls> means for websites is put
    /// back as *://*/*, which the refusals don't touch. A refusal for all hosts
    /// doesn't outweigh a grant naming one (WebKit looks at those first), which
    /// is why no such refusal is ever made.
    static func fence(_ context: WKWebExtensionContext) {
        let everything = context.grantedPermissionMatchPatterns.keys.contains {
            $0.matchesAllURLs
        }
        defer {
            if everything, let web = try? WKWebExtension.MatchPattern(string: "*://*/*") {
                context.setPermissionStatus(.grantedExplicitly, for: web)
            }
        }
        for scheme in extensionSchemes {
            if let pages = try? WKWebExtension.MatchPattern(string: "\(scheme)://*/*") {
                context.setPermissionStatus(.deniedExplicitly, for: pages)
            }
        }
        for string in ["file:///*", "file://*/*"] {
            if let files = try? WKWebExtension.MatchPattern(string: string) {
                context.setPermissionStatus(.deniedExplicitly, for: files)
            }
        }
    }
}
