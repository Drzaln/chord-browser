import Foundation
import Testing

@testable import BrowserCore

@Suite("Content-block refresh schedule (C3)")
struct ContentBlockRefreshTests {
    private let week = ContentBlockRefresh.interval
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("Never refreshed is always due")
    func neverRefreshed() {
        #expect(ContentBlockRefresh.isDue(lastRefresh: nil, now: now))
    }

    @Test("Due once the interval has fully elapsed")
    func elapsed() {
        #expect(
            ContentBlockRefresh.isDue(lastRefresh: now.addingTimeInterval(-week), now: now)
        )
        #expect(
            ContentBlockRefresh.isDue(lastRefresh: now.addingTimeInterval(-week - 1), now: now)
        )
    }

    @Test("Not due within the interval")
    func withinInterval() {
        #expect(
            !ContentBlockRefresh.isDue(lastRefresh: now.addingTimeInterval(-3600), now: now)
        )
        #expect(
            !ContentBlockRefresh.isDue(lastRefresh: now.addingTimeInterval(-week + 1), now: now)
        )
    }
}
