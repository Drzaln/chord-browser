import AppKit
import AVFoundation
import ChordEngine
import ChordStore
import ChordTestSupport
import Foundation
import Testing

/// End-to-end verification of the app-driven Picture-in-Picture command
/// (non-spec: user-requested) against a real `WKWebView`.
///
/// The critical regression this guards: `callAsyncJavaScript` evaluates the
/// toggle script as a *function body*, so a result wrapped in an IIFE was
/// swallowed and the engine got `undefined` → `.unsupported` → a silent no-op.
/// These tests pin the result plumbing to a real value.
@Suite("E2E: picture in picture")
@MainActor
struct PictureInPictureE2ETests {

    @Test("Toggle on a page with no video reports noVideo, not a swallowed result")
    func noVideoReportsCleanly() async throws {
        let harness = try await E2EHarness.make(routes: [
            .page(path: "/plain", title: "Plain"),
        ])
        defer { Task { await harness.tearDown() } }

        await harness.store.restore()
        guard await harness.openAndLoad(harness.server.url("/plain")) else {
            Issue.record("page did not load")
            return
        }
        let paneID = harness.store.selectedTab?.focusedPaneID
        #expect(paneID != nil)
        guard let paneID else { return }

        let result = await harness.engine.togglePictureInPicture(paneID: paneID)
        #expect(result == .noVideo)
    }

    @Test("Toggle floats a real loaded video and reports entered")
    func floatsLoadedVideo() async throws {
        let clip = try await makeTestClip()
        let harness = try await E2EHarness.make(routes: [
            .page(path: "/player", title: "Player", body: """
                <video id="v" src="/clip.mp4" preload="auto" muted loop playsinline></video>
                <script>document.getElementById('v').play();</script>
                """),
            .media(path: "/clip.mp4", data: clip),
        ])
        defer { Task { await harness.tearDown() } }

        await harness.store.restore()
        guard await harness.openAndLoad(harness.server.url("/player")) else {
            Issue.record("player page did not load")
            return
        }
        let paneID = harness.store.selectedTab?.focusedPaneID
        #expect(paneID != nil)
        guard let paneID else { return }

        // A detached view has no window context for WebKit's presentation
        // layer, so host the web view the way the app does.
        let window = hostWindow(for: harness, paneID: paneID)
        defer { window.orderOut(nil as Any?) }

        // Metadata (and thus a piPable, non-blank video) arrives asynchronously;
        // poll the command itself until it has something to float.
        var result: PictureInPictureResult = .noVideo
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            result = await harness.engine.togglePictureInPicture(paneID: paneID)
            if result == .entered { break }
            try? await Task.sleep(for: .milliseconds(250))
        }

        #expect(result == .entered)
    }

/// Hosts the pane's live web view in a real window, so WebKit has the
    /// window context its media presentation layer needs.
    private func hostWindow(for harness: E2EHarness, paneID: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = harness.engine.paneWebView(paneID)
        window.orderFront(nil)
        return window
    }

    /// A one-frame H.264 clip, generated on the fly so the test is hermetic.
    /// All that matters is that WebKit can demux it and reach HAVE_METADATA —
    /// a blank black frame is fine.
    private func makeTestClip() async throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pip-clip-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 90,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 90,
            ]
        )
        writer.add(input)

        guard writer.startWriting(),
            let pool = adaptor.pixelBufferPool,
            let buffer = makePixelBuffer(from: pool)
        else {
            throw NSError(domain: "PictureInPictureE2E", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "could not start AVAssetWriter"
            ])
        }
        writer.startSession(atSourceTime: .zero)
        adaptor.append(buffer, withPresentationTime: .zero)
        input.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw NSError(domain: "PictureInPictureE2E", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "clip encode failed: \(writer.error?.localizedDescription ?? "?")"
            ])
        }
        return try Data(contentsOf: url)
    }

    private func makePixelBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
            let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}