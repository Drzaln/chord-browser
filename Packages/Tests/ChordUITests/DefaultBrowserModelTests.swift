import ChordCore
import Testing

@testable import ChordUI

/// The Settings "Default browser" row, against a fake so no test touches the
/// Mac's real default.
@Suite("Default browser row")
@MainActor
struct DefaultBrowserModelTests {

    private final class FakeDefaultBrowser: DefaultBrowserControlling {
        var isDefault: Bool
        /// What `makeDefault` leaves behind: true for "Use Chord", false for
        /// "Keep Safari".
        var userAccepts: Bool
        var declineThrows = false
        private(set) var requests = 0

        init(isDefault: Bool, userAccepts: Bool = true) {
            self.isDefault = isDefault
            self.userAccepts = userAccepts
        }

        func makeDefault() async throws {
            requests += 1
            if userAccepts {
                isDefault = true
            } else if declineThrows {
                throw CancellationError()
            }
        }
    }

    @Test("Not default: the button asks once, and the row reads the new state")
    func makeDefaultAsksOnce() async {
        let fake = FakeDefaultBrowser(isDefault: false)
        let model = DefaultBrowserModel(control: fake)
        #expect(!model.isDefault)

        await model.makeDefault()

        #expect(fake.requests == 1)
        #expect(model.isDefault)
        #expect(!model.isAsking)
    }

    @Test("Already default: the row shows it")
    func alreadyDefault() {
        let model = DefaultBrowserModel(control: FakeDefaultBrowser(isDefault: true))
        #expect(model.isDefault)
    }

    @Test("Keeping the other browser leaves the row on not-default, thrown or not")
    func declined() async {
        for throwing in [false, true] {
            let fake = FakeDefaultBrowser(isDefault: false, userAccepts: false)
            fake.declineThrows = throwing
            let model = DefaultBrowserModel(control: fake)
            await model.makeDefault()
            #expect(!model.isDefault)
            #expect(!model.isAsking)
        }
    }

    @Test("A change made in System Settings shows on refresh")
    func refreshReadsOutsideChange() {
        let fake = FakeDefaultBrowser(isDefault: false)
        let model = DefaultBrowserModel(control: fake)
        fake.isDefault = true
        model.refresh()
        #expect(model.isDefault)
    }
}
