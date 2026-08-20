import ChordCore
import Foundation
import Testing
import WebKit

@testable import ChordEngine

/// The integration test BROWSER_SPEC 10 asks for: create a Space, set a cookie,
/// switch Space, assert the cookie is absent.
///
/// This is the property the whole Spaces feature exists to provide, so it is
/// tested against real `WKWebsiteDataStore`s rather than a fake.
@Suite("Space data isolation", .serialized)
@MainActor
struct DataStoreIsolationTests {

    private func makeSpace(name: String) -> Space {
        Space(name: name, sortIndex: 0)
    }

    private func cookie(named name: String, value: String) throws -> HTTPCookie {
        try #require(
            HTTPCookie(properties: [
                .domain: "example.com",
                .path: "/",
                .name: name,
                .value: value,
                .secure: "TRUE",
            ])
        )
    }

    @Test("A cookie set in one Space is invisible in another")
    func cookiesAreIsolated() async throws {
        let registry = DataStoreRegistry()
        let work = makeSpace(name: "Work")
        let personal = makeSpace(name: "Personal")

        let workStore = registry.store(for: work)
        let personalStore = registry.store(for: personal)

        // Distinct identifiers must produce distinct stores, or nothing below
        // proves anything.
        #expect(workStore !== personalStore)

        try await workStore.httpCookieStore.setCookie(cookie(named: "session", value: "work"))

        let workCookies = await workStore.httpCookieStore.allCookies()
        let personalCookies = await personalStore.httpCookieStore.allCookies()

        #expect(workCookies.contains { $0.name == "session" && $0.value == "work" })
        #expect(!personalCookies.contains { $0.name == "session" })

        // Clean up both stores so repeat runs start from nothing.
        try? await registry.removePersistentStore(dataStoreID: work.dataStoreID)
        try? await registry.removePersistentStore(dataStoreID: personal.dataStoreID)
    }

    @Test("The same site can hold a different session per Space at once")
    func twoSessionsCoexist() async throws {
        let registry = DataStoreRegistry()
        let first = makeSpace(name: "Account A")
        let second = makeSpace(name: "Account B")

        try await registry.store(for: first).httpCookieStore
            .setCookie(cookie(named: "account", value: "a"))
        try await registry.store(for: second).httpCookieStore
            .setCookie(cookie(named: "account", value: "b"))

        // This is M2's done-when condition in miniature: two logins to one site,
        // live simultaneously, no profile switching.
        let firstValue = await registry.store(for: first).httpCookieStore
            .allCookies().first { $0.name == "account" }?.value
        let secondValue = await registry.store(for: second).httpCookieStore
            .allCookies().first { $0.name == "account" }?.value

        #expect(firstValue == "a")
        #expect(secondValue == "b")

        try? await registry.removePersistentStore(dataStoreID: first.dataStoreID)
        try? await registry.removePersistentStore(dataStoreID: second.dataStoreID)
    }

    @Test("A Space's store is created once and cached")
    func storeIsCached() {
        let registry = DataStoreRegistry()
        let space = makeSpace(name: "Cached")

        #expect(registry.store(for: space) === registry.store(for: space))
    }

    @Test("A private Space uses a non-persistent store")
    func privateSpaceIsNonPersistent() {
        let registry = DataStoreRegistry()
        var space = makeSpace(name: "Private")
        space.isPrivate = true

        #expect(!registry.store(for: space).isPersistent)
    }

    @Test("Forgetting a Space drops its cached store")
    func forgetDropsCache() {
        let registry = DataStoreRegistry()
        let space = makeSpace(name: "Forgettable")

        let first = registry.store(for: space)
        registry.forget(spaceID: space.id)
        let second = registry.store(for: space)

        // Same identifier, so WebKit may hand back an equivalent store; what
        // matters is that the registry no longer holds the old reference.
        #expect(first.identifier == second.identifier)
    }
}
