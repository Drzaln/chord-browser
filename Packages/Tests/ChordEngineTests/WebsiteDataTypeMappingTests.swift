import ChordCore
import Testing
import WebKit

@testable import ChordEngine

@Suite("Website data-type mapping")
struct WebsiteDataTypeMappingTests {
    @Test("Cache maps to the WebKit cache constants and nothing else")
    func cacheMapping() {
        let set = WebKitEngine.websiteDataTypes(for: .cache)
        #expect(set.contains(WKWebsiteDataTypeDiskCache))
        #expect(set.contains(WKWebsiteDataTypeMemoryCache))
        #expect(!set.contains(WKWebsiteDataTypeCookies))
        #expect(!set.contains(WKWebsiteDataTypeLocalStorage))
    }

    @Test("Cookies map to the cookie constant")
    func cookieMapping() {
        #expect(WebKitEngine.websiteDataTypes(for: .cookies) == [WKWebsiteDataTypeCookies])
    }

    @Test("Site storage maps to local/session/IndexedDB/etc")
    func siteStorageMapping() {
        let set = WebKitEngine.websiteDataTypes(for: .siteStorage)
        #expect(set.contains(WKWebsiteDataTypeLocalStorage))
        #expect(set.contains(WKWebsiteDataTypeIndexedDBDatabases))
        #expect(set.contains(WKWebsiteDataTypeServiceWorkerRegistrations))
        #expect(!set.contains(WKWebsiteDataTypeCookies))
    }

    @Test("History alone maps to no website data types")
    func historyMapsToNothing() {
        #expect(WebKitEngine.websiteDataTypes(for: .history).isEmpty)
    }
}
