import ChordCore
import Testing

@Suite("Browsing data types")
struct BrowsingDataTypeTests {
    @Test("`all` contains every category")
    func allContainsEverything() {
        #expect(BrowsingDataType.all.contains(.cache))
        #expect(BrowsingDataType.all.contains(.cookies))
        #expect(BrowsingDataType.all.contains(.siteStorage))
        #expect(BrowsingDataType.all.contains(.history))
    }

    @Test("`websiteDataTypes` drops history, keeps the WebKit-store categories")
    func websiteDataTypesExcludesHistory() {
        let web = BrowsingDataType.all.websiteDataTypes
        #expect(!web.contains(.history))
        #expect(web.contains(.cache))
        #expect(web.contains(.cookies))
        #expect(web.contains(.siteStorage))
    }

    @Test("History-only selection yields no website data types")
    func historyOnlyHasNoWebsiteTypes() {
        #expect(BrowsingDataType.history.websiteDataTypes.isEmpty)
    }
}
