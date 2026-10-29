import Foundation
import Testing

@testable import ChordExtensions

/// WebKit doesn't always call a port's disconnect handler when it unloads an
/// extension, so the sockets a worker opened are ended by the browser: those
/// of an unloaded context, and any whose port is gone. A real
/// `WKWebExtension.MessagePort` can't be made in a test, so these drive the
/// registry the connections live in.
@Suite("Extension sockets", .serialized)
@MainActor
struct ExtensionSocketTests {

    /// A registered stand-in for one connection: ending it records the end and
    /// leaves the registry, as `Connection.end` does through `onEnd`.
    @MainActor
    private final class Stub {
        var ended = false
        var orphan = false
        init(context: NSObject) {
            let key = ObjectIdentifier(self)
            ExtensionSocket.keep(
                key, context: ObjectIdentifier(context),
                isOrphan: { [unowned self] in orphan },
                end: { [unowned self] in
                    ended = true
                    ExtensionSocket.forget(key)
                }
            )
        }
    }

    @Test("Unloading a context ends its sockets, and only its sockets")
    func unloadEndsThatContextsSockets() {
        let unloaded = NSObject(), otherSpace = NSObject()
        let mine = [Stub(context: unloaded), Stub(context: unloaded)]
        let theirs = Stub(context: otherSpace)
        defer { ExtensionSocket.endConnections(of: ObjectIdentifier(otherSpace)) }
        let before = ExtensionSocket.openCount

        ExtensionSocket.endConnections(of: ObjectIdentifier(unloaded))

        #expect(mine.allSatisfy { $0.ended })
        #expect(!theirs.ended)
        #expect(ExtensionSocket.openCount == before - 2)
    }

    @Test("A socket whose port is gone is ended by the sweep")
    func sweepEndsOrphans() {
        let context = NSObject()
        let gone = Stub(context: context), live = Stub(context: context)
        defer { ExtensionSocket.endConnections(of: ObjectIdentifier(context)) }
        gone.orphan = true

        ExtensionSocket.endOrphans()

        #expect(gone.ended)
        #expect(!live.ended)
    }
}
