import ChordCore
import Foundation
import Testing
import WebKit

@testable import ChordExtensions

/// A removed extension's data wipe is recorded until it finishes, so one cut
/// short by a quit or crash is finished at the next launch (1mm.6.3).
@Suite("Extension data wipe", .serialized)
@MainActor
struct ExtensionForgetTests {
    private let key = WebKitExtensionHost.forgettingKey

    private func entries() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    @Test("A finished wipe leaves nothing to retry")
    func finishedWipeIsCleared() async {
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let host = WebKitExtensionHost()
        let space = Space(name: "Work", sortIndex: 0)

        await host.forgetData(identifier: "abcdefghijklmnopabcdefghijklmnop", in: [space])

        #expect(!entries().contains { $0.hasPrefix(space.id.uuidString) })
    }

    @Test("Launch retries a wipe the last run left, and drops one for a gone Space")
    func leftOverWipesAreRetried() async {
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let space = Space(name: "Work", sortIndex: 0)
        let gone = UUID()
        UserDefaults.standard.set([
            "\(space.id)|abcdefghijklmnopabcdefghijklmnop",
            "\(gone)|abcdefghijklmnopabcdefghijklmnop",
        ], forKey: key)
        let host = WebKitExtensionHost()

        await host.forgetLeftOver(in: [space])

        #expect(entries().isEmpty)
    }

    @Test("A private Space's wipe is never recorded")
    func privateSpaceIsNeverRecorded() async {
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let host = WebKitExtensionHost()
        let privateSpace = Space(name: "Private", sortIndex: 0, isPrivate: true)

        await host.forgetData(identifier: "abcdefghijklmnopabcdefghijklmnop", in: [privateSpace])

        #expect(entries().isEmpty, "nothing of a private Space persists to retry")
    }

    @Test("A wipe that fails stays recorded for the next launch")
    func failedWipeIsKept() async {
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let host = WebKitExtensionHost()
        let space = Space(name: "Work", sortIndex: 0)
        // Not an id a chrome-extension:// origin can be built from, so the
        // origin half of the wipe can't run and it reports failure.
        let broken = "not an id"

        await host.forgetData(identifier: broken, in: [space])

        #expect(entries() == ["\(space.id)|\(broken)"])
    }
}
