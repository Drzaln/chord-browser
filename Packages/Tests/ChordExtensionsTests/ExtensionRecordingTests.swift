import Foundation
import Testing
import WebKit

@testable import ChordExtensions

/// 1mm.15: the capture bridge knows what an extension is recording, says so
/// when it starts and stops, and its Stop ends it.
@MainActor
struct ExtensionRecordingTests {
    /// A page that records without a microphone: the capture state WebKit
    /// would report, with the change notifications it would send. (The test
    /// runner has no usage descriptions, so WebKit hides mediaDevices.)
    final class RecordingPage: WKWebView {
        var fakeMicrophone: WKMediaCaptureState = .none {
            willSet { willChangeValue(forKey: "microphoneCaptureState") }
            didSet { didChangeValue(forKey: "microphoneCaptureState") }
        }
        override var microphoneCaptureState: WKMediaCaptureState { fakeMicrophone }
        override func setMicrophoneCaptureState(
            _ state: WKMediaCaptureState, completionHandler: (@MainActor () -> Void)? = nil
        ) {
            fakeMicrophone = state
            completionHandler?()
        }
    }

    @Test func what() {
        let screen = ExtensionRecording(id: "a", name: "Loom", screen: true, camera: true, microphone: true)
        #expect(screen.what == "is recording your screen")
        let both = ExtensionRecording(id: "a", name: "Loom", screen: false, camera: true, microphone: true)
        #expect(both.what == "is using your camera and microphone")
        let mic = ExtensionRecording(id: "a", name: "Loom", screen: false, camera: false, microphone: true)
        #expect(mic.what == "is using your microphone")
    }

    @Test func aRecordingPageIsReportedAndStopEndsIt() async throws {
        let web = RecordingPage(frame: .zero, configuration: WKWebViewConfiguration())
        let capture = ExtensionCapture()
        var reports: [[ExtensionCapture.Watched.State]] = []
        capture.onRecordingsChanged = { reports.append($0) }

        // Handed a recording: watched, though WebKit reports nothing yet.
        capture.watch(web, extensionID: "loom")
        #expect(capture.recordings.isEmpty)

        web.fakeMicrophone = .active
        try await Task.sleep(for: .milliseconds(50))
        #expect(capture.recordings.map(\.extensionID) == ["loom"])
        #expect(capture.recordings.first?.microphone == true)
        #expect(reports.last?.first?.extensionID == "loom")

        // Another extension's Stop leaves it alone; its own ends it.
        capture.stop("other")
        #expect(web.fakeMicrophone == .active)
        capture.stop("loom")
        try await Task.sleep(for: .milliseconds(50))
        #expect(web.fakeMicrophone == .none)
        #expect(capture.recordings.isEmpty)
        #expect(reports.last?.isEmpty == true, "the pill is told the recording ended")
    }

    @Test func unloadingTheExtensionStopsItsRecording() async throws {
        let web = RecordingPage(frame: .zero, configuration: WKWebViewConfiguration())
        let capture = ExtensionCapture()
        capture.watch(web, extensionID: "loom")
        web.fakeMicrophone = .active
        try await Task.sleep(for: .milliseconds(50))
        capture.purge("loom")
        #expect(web.fakeMicrophone == .none)
    }
}
