import Foundation
import WebKit

/// What a context is given as it loads, beyond its declared API permissions,
/// and what it is never given. Ported from Search's `Extensions.load`,
/// `fence`, `withheld` and `grantSites`. An installed extension gets the sites
/// its manifest names, in every Space, as in Chrome: the install was the yes.
@MainActor
enum ExtensionGrants {
    private static let extensionSchemes = ["chrome-extension", "webkit-extension"]

    /// Load-time grants, after the declared permissions.
    static func applyAtLoad(
        to context: WKWebExtensionContext, identifier: String, inPrivateSpace: Bool,
        consented: Bool
    ) {
        // The install question named its sites, so the yes covers them, as
        // in Chrome. Optional ones are still asked for when it asks.
        if consented { grantSites(context) }
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
        // A private Space's pages are private data. The user let the extension
        // in (it is only loaded there if they did), unless its manifest
        // refuses, which Chrome honours and WebKit doesn't read.
        context.hasAccessToPrivateData = inPrivateSpace
            && (context.webExtension.manifest["incognito"] as? String) != "not_allowed"
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

    /// The sites a page-access question is about, one pattern each
    /// (`https://www.youtube.com/*`). Chrome and Safari ask per site: a yes
    /// for one video is a yes for the next. URLs with no host, or that reach
    /// extension pages or files, give none.
    static func sitePatterns(for urls: Set<URL>) -> [WKWebExtension.MatchPattern] {
        let sites = Set(urls.compactMap { url -> String? in
            guard let scheme = url.scheme?.lowercased(), let host = url.host(), !host.isEmpty
            else { return nil }
            return "\(scheme)://\(host.lowercased())/*"
        })
        return sites.sorted().compactMap { try? WKWebExtension.MatchPattern(string: $0) }
            .filter { !withheld($0) }
    }

    /// What a page-access question offers: every site, for an extension whose
    /// manifest asks for all of them (Bitwarden, uBlock), as Chrome grants at
    /// install; otherwise the sites the pages are on.
    static func accessToOffer(
        for urls: Set<URL>, wanted webExtension: WKWebExtension
    ) -> [WKWebExtension.MatchPattern] {
        let wanted = webExtension.allRequestedMatchPatterns
            .union(webExtension.optionalPermissionMatchPatterns)
        let wantsEverySite = wanted.contains {
            !withheld($0) && ($0.matchesAllHosts || $0.matchesAllURLs)
        }
        if wantsEverySite, let web = try? WKWebExtension.MatchPattern(string: "*://*/*") {
            return [web]
        }
        return sitePatterns(for: urls)
    }

    /// The sites its manifest names, never ones that reach extension pages or
    /// files (`fence` runs after). WebKit copies injected scripts per granted
    /// pattern, so a pattern a broader one already covers (same scheme and
    /// path) isn't granted again.
    static func grantSites(_ context: WKWebExtensionContext) {
        let patterns = context.webExtension.allRequestedMatchPatterns.filter { !withheld($0) }
        for pattern in patterns {
            let covered = patterns.contains { other in
                other.string != pattern.string && other.scheme == pattern.scheme
                    && other.path == pattern.path && other.matches(pattern)
                    && (!pattern.matches(other) || other.string < pattern.string)
            }
            guard !covered else { continue }
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
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
