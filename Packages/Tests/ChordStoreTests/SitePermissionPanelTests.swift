import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// The prompt is appended and the decision written in store tasks *behind* the
/// page's awaited request, so a test polls for both rather than assuming an
/// interleaving.
@MainActor
private func waitForSitePermissionPrompt(_ store: TabStore) async -> SitePermissionPrompt? {
    for _ in 0..<1_000 {
        if let first = store.pendingSitePermissionPrompts.first { return first }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return nil
}

@MainActor
private func waitForSitePermissionDecision(
    _ permissions: FakeSitePermissions, origin: String, spaceID: UUID, kind: SitePermissionKind
) async -> SitePermissionDecision? {
    for _ in 0..<1_000 {
        if let decision = await permissions.decision(
            origin: origin, spaceID: spaceID, kind: kind
        ) { return decision }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return nil
}

/// Camera/microphone asks are remembered per `(Space, origin, kind)` (ADR 014) —
/// which needs a Space. A pane in a tab supplies one; the floating Little Chord /
/// Peek panel (4.6) is a real browsing surface that belongs to no `Tab`, so its
/// Space can only come from the engine, which built the view against a Space's
/// data store. Without that answer the panel page was asked again on every visit
/// and nothing was ever remembered (the reported Meet bug: the same invite link
/// from Gmail/Calendar opens the panel, and "meet.google.com wants to use your
/// Camera and Microphone" reappeared every time).
// A request that misses a remembered answer waits on a prompt nobody answers,
// so a race here would hang the run: the limit turns that into a failure.
@Suite("Camera and microphone site permission", .timeLimit(.minutes(1)))
@MainActor
struct MediaCapturePermissionTests {

    private func makeStore(
        stored: [Tab] = [TabBuilder().url("https://meet.google.com/abc-defg-hij").build()]
    ) async -> (TabStore, FakeSitePermissions) {
        let repository = FakeTabRepository(stored: stored, spaces: [TabBuilder.defaultSpace()])
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: repository,
            spaceRepository: repository,
            clock: FixedClock()
        )
        let permissions = FakeSitePermissions()
        store.sitePermissions = permissions
        await store.restore()
        return (store, permissions)
    }

    private func waitForPrompt(_ store: TabStore) async -> SitePermissionPrompt? {
        await waitForSitePermissionPrompt(store)
    }

    /// The write runs in a store task behind the resumed page request, so a test
    /// asserting the stored row has to poll for it.
    private func waitForDecision(
        _ permissions: FakeSitePermissions, origin: String, spaceID: UUID,
        kind: SitePermissionKind
    ) async -> SitePermissionDecision? {
        await waitForSitePermissionDecision(
            permissions, origin: origin, spaceID: spaceID, kind: kind
        )
    }

    @Test("Both camera and microphone are asked together, then remembered for the Space")
    func askOnceForCameraAndMicrophone() async {
        let (store, permissions) = await makeStore()
        let tab = try! #require(store.visibleTabs.first)
        let prompt = SitePermissionPrompt(
            origin: "https://meet.google.com",
            host: "meet.google.com",
            kinds: [.camera, .microphone],
            paneID: tab.focusedPaneID
        )

        let request = Task { await store.paneRequestedMediaCapture(prompt) }
        let shown = try! #require(await waitForPrompt(store))
        #expect(shown.kinds == [.camera, .microphone])
        #expect(shown.host == "meet.google.com")

        store.resolveSitePermission(shown.id, allow: true)
        #expect(await request.value)

        #expect(
            await waitForDecision(
                permissions, origin: "https://meet.google.com",
                spaceID: TabBuilder.defaultSpaceID, kind: .camera
            ) == .granted
        )
        #expect(
            await waitForDecision(
                permissions, origin: "https://meet.google.com",
                spaceID: TabBuilder.defaultSpaceID, kind: .microphone
            ) == .granted
        )

        // Next visit in the same Space: remembered, no prompt.
        #expect(await store.paneRequestedMediaCapture(prompt))
        #expect(store.pendingSitePermissionPrompts.isEmpty)
    }

    @Test("A remembered denial blocks the site without prompting again")
    func askOnceDenies() async {
        let (store, permissions) = await makeStore()
        let tab = try! #require(store.visibleTabs.first)
        let prompt = SitePermissionPrompt(
            origin: "https://meet.google.com",
            host: "meet.google.com",
            kinds: [.camera, .microphone],
            paneID: tab.focusedPaneID
        )

        let request = Task { await store.paneRequestedMediaCapture(prompt) }
        let shown = try! #require(await waitForPrompt(store))
        store.resolveSitePermission(shown.id, allow: false)
        #expect(await request.value == false)
        // Written in a store task behind the answer: without this wait the next
        // request could miss it, prompt again, and wait for ever (x4b).
        #expect(
            await waitForDecision(
                permissions, origin: "https://meet.google.com",
                spaceID: TabBuilder.defaultSpaceID, kind: .microphone
            ) == .denied
        )

        #expect(await store.paneRequestedMediaCapture(prompt) == false)
        #expect(store.pendingSitePermissionPrompts.isEmpty)
    }
}

/// The same ask-once behaviour for a pane that is in no `Tab`.
@Suite("Site permission for a pane in no tab", .timeLimit(.minutes(1)))
@MainActor
struct PanelSitePermissionTests {

    private func makeStore() async -> (TabStore, FakeSitePermissions) {
        let repository = FakeTabRepository(
            stored: [TabBuilder().url("https://meet.google.com/home").build()],
            spaces: [TabBuilder.defaultSpace()]
        )
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: repository,
            spaceRepository: repository,
            clock: FixedClock()
        )
        let permissions = FakeSitePermissions()
        store.sitePermissions = permissions
        await store.restore()
        return (store, permissions)
    }

    private func waitForPrompt(_ store: TabStore) async -> SitePermissionPrompt? {
        await waitForSitePermissionPrompt(store)
    }

    private func waitForDecision(
        _ permissions: FakeSitePermissions, origin: String, spaceID: UUID,
        kind: SitePermissionKind
    ) async -> SitePermissionDecision? {
        await waitForSitePermissionDecision(
            permissions, origin: origin, spaceID: spaceID, kind: kind
        )
    }

    /// A panel page, exactly as the app builds one: a pane in no tab, shown
    /// through the engine in a Space (the Peek panel opens in the Space the click
    /// came from).
    private func makePanelPane(_ store: TabStore) -> Pane {
        let pane = store.makeLittleChordPane(
            url: URL(string: "https://meet.google.com/abc-defg-hij")!
        )
        _ = store.littleChordSurface(for: pane, in: TabBuilder.defaultSpaceID)
        return pane
    }

    @Test("A panel page is remembered for the Space it was shown in")
    func panelPaneRemembers() async {
        let (store, permissions) = await makeStore()
        let pane = makePanelPane(store)
        // Not in any tab — which is the whole reason the engine's answer exists.
        #expect(store.spaceID(forPane: pane.id) == nil)

        let prompt = SitePermissionPrompt(
            origin: "https://meet.google.com",
            host: "meet.google.com",
            kinds: [.camera, .microphone],
            paneID: pane.id
        )

        let request = Task { await store.paneRequestedMediaCapture(prompt) }
        let shown = try! #require(await waitForPrompt(store))
        store.resolveSitePermission(shown.id, allow: true)
        #expect(await request.value)

        // The microphone row is written after the camera's, so waiting on it
        // means both have landed before the next request reads them.
        #expect(
            await waitForDecision(
                permissions, origin: "https://meet.google.com",
                spaceID: TabBuilder.defaultSpaceID, kind: .microphone
            ) == .granted
        )

        // The next link from the same Space opens a fresh panel pane and is not
        // asked again.
        let second = makePanelPane(store)
        let secondPrompt = SitePermissionPrompt(
            origin: "https://meet.google.com",
            host: "meet.google.com",
            kinds: [.camera, .microphone],
            paneID: second.id
        )
        #expect(await store.paneRequestedMediaCapture(secondPrompt))
        #expect(store.pendingSitePermissionPrompts.isEmpty)
    }

    @Test("The state queries answer a panel pane from the same remembered decision")
    func panelPaneStateQueries() async {
        let (store, permissions) = await makeStore()
        let pane = makePanelPane(store)

        #expect(
            await store.paneNotificationPermissionState(
                origin: "https://meet.google.com", paneID: pane.id
            ) == .notDetermined
        )

        let prompt = SitePermissionPrompt(
            origin: "https://meet.google.com",
            host: "meet.google.com",
            kinds: [.notification],
            paneID: pane.id
        )
        let request = Task { await store.paneRequestedNotificationPermission(prompt) }
        let shown = try! #require(await waitForPrompt(store))
        store.resolveSitePermission(shown.id, allow: true)
        #expect(await request.value)
        #expect(
            await waitForDecision(
                permissions, origin: "https://meet.google.com",
                spaceID: TabBuilder.defaultSpaceID, kind: .notification
            ) == .granted
        )

        #expect(
            await store.paneNotificationPermissionState(
                origin: "https://meet.google.com", paneID: pane.id
            ) == .granted
        )
    }

    @Test("With no Space from the engine a panel page still prompts each time")
    func panelPaneWithoutSpaceStillPrompts() async {
        let (store, _) = await makeStore()
        // No surface, so the engine has no Space for this pane — the degraded
        // path. The page still gets its answer; it is just not remembered.
        let pane = store.makeLittleChordPane(
            url: URL(string: "https://meet.google.com/abc-defg-hij")!
        )
        let prompt = SitePermissionPrompt(
            origin: "https://meet.google.com",
            host: "meet.google.com",
            kinds: [.camera],
            paneID: pane.id
        )

        let first = Task { await store.paneRequestedMediaCapture(prompt) }
        let firstShown = try! #require(await waitForPrompt(store))
        store.resolveSitePermission(firstShown.id, allow: true)
        #expect(await first.value)

        let second = Task { await store.paneRequestedMediaCapture(prompt) }
        #expect(await waitForPrompt(store) != nil)
        if let secondShown = store.pendingSitePermissionPrompts.first {
            store.resolveSitePermission(secondShown.id, allow: true)
        }
        #expect(await second.value)
    }
}
