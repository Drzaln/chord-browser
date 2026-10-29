import ChordCore
import Foundation

/// Per-site behaviour: where a site's links land (routing rules, ADR 023) and
/// how a site looks (overrides, ADR 024).
///
/// Both are "small choices about a domain", both are stored as preferences
/// rather than rows, and both are applied by the engine at navigation time. They
/// live together because the Settings pane presents them together.
extension TabStore {

    // MARK: - Routing rules

    /// Hands the engine the whole override list. The engine rebuilds the injected
    /// script, so a page picks the change up on its next load.
    func pushSiteOverrides() {
        engine.setSiteOverrides(siteOverrides)
    }

    /// Adds or replaces a rule, normalising what the user typed. Returns false
    /// when the input is not a host or the Space is not one of ours, so Settings
    /// can say so rather than storing a rule that can never fire.
    @discardableResult
    public func setRouteRule(
        pattern: String, spaceID: UUID, routesNewTabs: Bool = true, isEnabled: Bool = true
    ) -> Bool {
        guard let normalised = RouteRules.normalise(pattern),
            spaces.contains(where: { $0.id == spaceID && !$0.isPrivate })
        else { return false }
        var updated = routeRules.filter { $0.pattern != normalised }
        updated.append(
            RouteRule(
                pattern: normalised, spaceID: spaceID, routesNewTabs: routesNewTabs,
                isEnabled: isEnabled
            )
        )
        routeRules = updated.sorted { $0.pattern < $1.pattern }
        return true
    }

    public func removeRouteRule(pattern: String) {
        routeRules.removeAll { $0.pattern == pattern }
    }

    /// The Space an arriving URL belongs in, or nil when no rule applies.
    ///
    /// Private windows are excluded wholesale: a rule firing there would either
    /// move the visit into a persistent Space (a leak) or be ignored, and being
    /// ignored is simpler and matches a private window being locked to one Space.
    public func spaceID(
        forRouted url: URL, kind: RoutedOpenKind, in window: WindowState
    ) -> UUID? {
        guard !window.isPrivate else { return nil }
        return RouteRules.destination(
            for: url,
            kind: kind,
            rules: routeRules,
            knownSpaceIDs: Set(spaces.filter { !$0.isPrivate }.map(\.id))
        )
    }

    /// The single entry point for a URL handed to the app by macOS (another app,
    /// a Dock drop, Spotlight).
    ///
    /// Without a rule this is the Little Chord panel, as before (§4.6). With one,
    /// the link is *launched*: the window switches to the Space and selects the
    /// tab, because a link the user asked the system to open has to be visible —
    /// unlike a ⌘-click, which must not yank the window.
    public func openExternally(_ url: URL) {
        let window = focusedNonPrivateWindow
        guard let spaceID = spaceID(forRouted: url, kind: .external, in: window),
            let space = spaces.first(where: { $0.id == spaceID })
        else {
            littleChordPresenter?(url)
            return
        }
        let tabID = insertTab(
            panes: [Pane(url: url)], in: window, spaceID: spaceID, selecting: true
        )
        window.showToast(
            "Opened in \(space.name)", icon: "arrow.turn.down.right",
            action: { [weak self, weak window] in
                guard let self, let window else { return }
                window.dismissToast()
                self.select(tabID, in: window)
            }
        )
    }

    /// Additional URLs in a multi-link handoff (several links dragged in at
    /// once). Each opens as its own tab, still honouring a rule; unlike the first
    /// one these are selected tabs rather than a Little Chord panel, which is the
    /// behaviour they had before rules existed.
    public func openExternallyAlongside(_ url: URL) {
        let window = focusedNonPrivateWindow
        if let spaceID = spaceID(forRouted: url, kind: .external, in: window),
            let space = spaces.first(where: { $0.id == spaceID })
        {
            let tabID = insertTab(
                panes: [Pane(url: url)], in: window, spaceID: spaceID, selecting: true
            )
            window.showToast(
                "Opened in \(space.name)", icon: "arrow.turn.down.right",
                action: { [weak self, weak window] in
                    guard let self, let window else { return }
                    window.dismissToast()
                    self.select(tabID, in: window)
                }
            )
            return
        }
        newTab(url: url, in: window)
    }

    /// A local file handed over by macOS (a `.html` double-clicked in Finder,
    /// or "Open With"). It opens as a new, selected tab in the focused window's
    /// active Space: a file is a document to read, not a glance, so no Little
    /// Chord, and routing rules match hosts, which a file has none of.
    @discardableResult
    public func openFileExternally(_ url: URL) -> UUID {
        newTab(url: url, in: focusedNonPrivateWindow)
    }

    /// Opens a Cmd-clicked / `target=_blank` link, honouring a routing rule. A
    /// routed tab is appended to the target Space *without* switching the
    /// window: the gesture means "save this for later", so the reading position
    /// wins. Returns the new tab's id, or nil when it was not routed.
    @discardableResult
    func openRoutedBackgroundTab(url: URL, in window: WindowState) -> UUID? {
        guard let spaceID = spaceID(forRouted: url, kind: .newTab, in: window),
            let space = spaces.first(where: { $0.id == spaceID })
        else { return nil }
        let tabID = insertTab(
            panes: [Pane(url: url)], in: window, spaceID: spaceID, selecting: false
        )
        window.showToast(
            "Opened in \(space.name)", icon: "arrow.turn.down.right",
            action: { [weak self, weak window] in
                guard let self, let window else { return }
                window.dismissToast()
                self.selectSpace(spaceID, in: window)
                self.select(tabID, in: window)
            }
        )
        return tabID
    }

    // MARK: - Site overrides

    /// The enabled override that applies to a host, most specific wins.
    public func siteOverride(forHost host: String) -> SiteOverride? {
        SiteOverrides.match(host: host, in: siteOverrides)
    }

    /// What the Settings editor shows for a typed host: the matching override, or
    /// a fresh disabled-in-nothing draft that will be created on first save.
    public func siteOverrideDraft(pattern: String) -> SiteOverride? {
        guard let normalised = SiteOverrides.normalise(pattern) else { return nil }
        return siteOverrides.first(where: { $0.pattern == normalised })
            ?? SiteOverride(pattern: normalised)
    }

    /// Creates or replaces the record for its pattern. Returns false when the
    /// pattern is not a host, so Settings can refuse an empty rule.
    @discardableResult
    public func setSiteOverride(_ override: SiteOverride) -> Bool {
        guard let normalised = SiteOverrides.normalise(override.pattern) else { return false }
        var record = override
        record = SiteOverride(
            pattern: normalised,
            css: override.css,
            js: override.js,
            hiddenSelectors: override.hiddenSelectors,
            isEnabled: override.isEnabled
        )
        var updated = siteOverrides.filter { $0.pattern != normalised }
        updated.append(record)
        siteOverrides = updated.sorted { $0.pattern < $1.pattern }
        return true
    }

    public func removeSiteOverride(pattern: String) {
        siteOverrides.removeAll { $0.pattern == pattern }
    }

    /// Appends a selector zapped (or typed) by the user. Returns false when the
    /// selector is unusable or no override exists for that pattern yet — the
    /// zapper requires an override to write into, because "hide this element"
    /// is a per-site decision and not a global one.
    @discardableResult
    public func addHiddenSelector(_ selector: String, to pattern: String) -> Bool {
        guard SiteOverrides.isUsableSelector(selector),
            let index = siteOverrides.firstIndex(where: { $0.pattern == pattern })
        else { return false }
        let cleaned = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !siteOverrides[index].hiddenSelectors.contains(cleaned) else { return true }
        siteOverrides[index].hiddenSelectors.append(cleaned)
        return true
    }

    public func removeHiddenSelector(_ selector: String, from pattern: String) {
        guard let index = siteOverrides.firstIndex(where: { $0.pattern == pattern }) else { return }
        siteOverrides[index].hiddenSelectors.removeAll { $0 == selector }
    }

    // MARK: - Element picker

    /// Starts the click-to-hide picker for one override, on the focused window's
    /// current page. The user is told why nothing happens when there is no live
    /// page to pick on, rather than the button appearing to do nothing.
    public func beginElementPick(forPattern pattern: String) {
        let window = focusedWindow
        guard let tab = selectedTab(in: window) else {
            window.showToast("Open a page on \(pattern) first", icon: "exclamationmark.circle")
            return
        }
        pendingPickPattern = pattern
        if !engine.beginPickingElement(paneID: tab.focusedPaneID) {
            pendingPickPattern = nil
            window.showToast("Open a page on \(pattern) first", icon: "exclamationmark.circle")
        }
    }

    /// The picker chose an element. Refuses a pick made on another site: the
    /// selector would be meaningless (or wrong) in the override it would land in.
    public func panePickedSiteOverrideElement(
        selector: String, host: String, fromPane paneID: UUID
    ) {
        defer { pendingPickPattern = nil }
        let window = window(showingPane: paneID)
        guard let pattern = pendingPickPattern else { return }
        let normalisedHost = SiteOverrides.normalise(host)
        let isOnSite =
            normalisedHost == pattern
            || (normalisedHost?.hasSuffix("." + pattern) ?? false)
        guard isOnSite else {
            window.showToast(
                "That element is not on \(pattern)", icon: "exclamationmark.circle"
            )
            return
        }
        guard addHiddenSelector(selector, to: pattern) else {
            window.showToast("Could not use that element", icon: "exclamationmark.circle")
            return
        }
        window.showToast("Hidden \(selector)", icon: "eye.slash")
    }

    public func paneDidCancelSiteOverridePick(fromPane paneID: UUID) {
        pendingPickPattern = nil
    }
}
