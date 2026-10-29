import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// The per-origin geolocation prompt path (`paneRequestedGeolocation`): ask once,
/// remember, apply the same decision on later requests — the same ask-once
/// behaviour camera/mic and notifications already have, driven through the
/// WebKit geolocation delegate SPI.
// A request that misses a remembered answer waits on a prompt nobody answers,
// so a race here would hang the run: the limit turns that into a failure.
@Suite("Geolocation site permission", .timeLimit(.minutes(1)))
@MainActor
struct GeolocationPermissionTests {

    /// A store with the geolocation fake's repository attached.
    ///
    /// The `SitePermissionsRepository` is shared test support
    /// (`ChordTestSupport.FakeSitePermissions`), keyed on the whole
    /// `(Space, origin, kind)` tuple like the SQLite one.
    private func makeStore(
        stored: [Tab] = [TabBuilder().url("https://maps.google.com").build()]
    ) async -> (TabStore, FakeSitePermissions) {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: stored),
            clock: FixedClock()
        )
        let permissions = FakeSitePermissions()
        store.sitePermissions = permissions
        await store.restore()
        return (store, permissions)
    }

    /// The decision is written in a store task behind the resumed request, so
    /// a later request that should find it has to wait for it first.
    /// Fails, rather than silently timing out, if the decision never lands.
    private func waitForDecision(
        _ permissions: FakeSitePermissions, origin: String, in store: TabStore
    ) async {
        let spaceID = try! #require(store.visibleTabs.first?.spaceID)
        for _ in 0..<1_000 {
            if await permissions.decision(
                origin: origin, spaceID: spaceID, kind: .geolocation
            ) != nil { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("no geolocation decision was written for \(origin)")
    }

    private func waitForPrompt(_ store: TabStore) async -> SitePermissionPrompt? {
        for _ in 0..<1_000 {
            if let first = store.pendingSitePermissionPrompts.first { return first }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    @Test("First request prompts; granting remembers; a later request auto-grants")
    func askOnceGrant() async {
        let (store, permissions) = await makeStore()
        let tab = try! #require(store.visibleTabs.first)
        let prompt = SitePermissionPrompt(
            origin: "https://maps.google.com",
            host: "maps.google.com",
            kinds: [.geolocation],
            paneID: tab.focusedPaneID
        )

        // First visit: blocks on the prompt sheet, nothing decided yet.
        let request = Task { await store.paneRequestedGeolocation(prompt) }
        let shown = await waitForPrompt(store)
        let shownPrompt = try! #require(shown)
        #expect(shownPrompt.kinds == [.geolocation])
        #expect(shownPrompt.origin == "https://maps.google.com")

        store.resolveSitePermission(shownPrompt.id, allow: true)
        let firstGranted = await request.value
        #expect(firstGranted)
        await waitForDecision(permissions, origin: "https://maps.google.com", in: store)

        // Second visit: remembered grant, no prompt.
        let secondGranted = await store.paneRequestedGeolocation(prompt)
        #expect(secondGranted)
        #expect(store.pendingSitePermissionPrompts.isEmpty)
    }

    @Test("A remembered denial blocks the site without prompting again")
    func askOnceDeny() async {
        let (store, permissions) = await makeStore()
        let tab = try! #require(store.visibleTabs.first)
        let prompt = SitePermissionPrompt(
            origin: "https://maps.google.com",
            host: "maps.google.com",
            kinds: [.geolocation],
            paneID: tab.focusedPaneID
        )

        let request = Task { await store.paneRequestedGeolocation(prompt) }
        let shown = try! #require(await waitForPrompt(store))
        store.resolveSitePermission(shown.id, allow: false)
        #expect(await request.value == false)
        await waitForDecision(permissions, origin: "https://maps.google.com", in: store)

        let second = await store.paneRequestedGeolocation(prompt)
        #expect(second == false)
        #expect(store.pendingSitePermissionPrompts.isEmpty)
    }

    @Test("The state query reports the remembered decision without prompting")
    func stateQueryReflectsDecision() async {
        let (store, permissions) = await makeStore()
        let tab = try! #require(store.visibleTabs.first)
        let prompt = SitePermissionPrompt(
            origin: "https://maps.google.com",
            host: "maps.google.com",
            kinds: [.geolocation],
            paneID: tab.focusedPaneID
        )

        #expect(
            await store.paneGeolocationPermissionState(
                origin: "https://maps.google.com", paneID: tab.focusedPaneID
            ) == .notDetermined
        )

        let request = Task { await store.paneRequestedGeolocation(prompt) }
        let shown = try! #require(await waitForPrompt(store))
        store.resolveSitePermission(shown.id, allow: true)
        #expect(await request.value)
        await waitForDecision(permissions, origin: "https://maps.google.com", in: store)

        #expect(
            await store.paneGeolocationPermissionState(
                origin: "https://maps.google.com", paneID: tab.focusedPaneID
            ) == .granted
        )
        #expect(store.pendingSitePermissionPrompts.isEmpty)
    }

    @Test("Without a repository the store falls back to prompting every time")
    func noRepositoryPromptsEveryTime() async {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(
                stored: [TabBuilder().url("https://maps.google.com").build()]
            ),
            clock: FixedClock()
        )
        await store.restore()
        let tab = try! #require(store.visibleTabs.first)
        let prompt = SitePermissionPrompt(
            origin: "https://maps.google.com",
            host: "maps.google.com",
            kinds: [.geolocation],
            paneID: tab.focusedPaneID
        )

        let first = Task { await store.paneRequestedGeolocation(prompt) }
        let firstShown = try! #require(await waitForPrompt(store))
        store.resolveSitePermission(firstShown.id, allow: true)
        #expect(await first.value)

        let second = Task { await store.paneRequestedGeolocation(prompt) }
        let secondShown = try! #require(await waitForPrompt(store))
        store.resolveSitePermission(secondShown.id, allow: true)
        #expect(await second.value)
    }
}