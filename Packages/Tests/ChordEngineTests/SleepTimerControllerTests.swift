import WebKit
import Testing

@testable import ChordEngine

/// The sleep timer is a pure page-side user script (no message handler), so
/// these guard its injection shape and that it exposes the entry point the
/// engine calls when a timer fires.
@Suite("Sleep timer controller")
@MainActor
struct SleepTimerControllerTests {

    @Test("Injected at document start, into every frame")
    func injectionShape() {
        let script = SleepTimerController.makeUserScript()
        #expect(script.injectionTime == .atDocumentStart)
        #expect(script.isForMainFrameOnly == false)
    }

    @Test("Exposes the pause-all entry point the engine calls on fire")
    func exposesPauseAll() {
        let source = SleepTimerController.makeUserScript().source
        #expect(source.contains("__chordSleepTimerPauseAll"))
        #expect(source.contains("pause"))
    }
}
