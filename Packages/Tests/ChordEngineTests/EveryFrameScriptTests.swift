import Foundation
import Testing
import WebKit

@testable import ChordEngine

/// c1k.3: the page scripts every frame gets went in as ten; now one.
@Suite("Every-frame page scripts, as one")
@MainActor
struct EveryFrameScriptTests {

    @Test("The one script carries each part, each in its own try")
    func carriesEachPart() {
        let bundle = WebKitEngine.everyFrameSource
        for part in [
            MediaActivityMonitor.makeUserScript(), ContextLinkMonitor.makeUserScript(),
            ContextImageMonitor.makeUserScript(), AudioMuteController.makeUserScript(),
            SleepTimerController.makeUserScript(), NotificationBridge.makeUserScript(),
            ScreenShareMonitor.makeUserScript(), YouTubeAdBlocker.makeUserScript(),
            GeolocationBridge.makeUserScript(), PictureInPictureMonitor.makeUserScript(),
        ] {
            #expect(part.injectionTime == .atDocumentStart)
            #expect(!part.isForMainFrameOnly)
            #expect(bundle.contains("try {\n\(part.source)\n} catch (e) {}"))
        }
    }

    @Test("In a real page it runs whole: the YouTube part still speeds an ad")
    func runsInAPage() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebKitEngine.everyFrameSource, injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.loadHTMLString(
            #"<div class="html5-video-player ad-showing"><video id="v"></video></div>"#,
            baseURL: URL(string: "https://www.youtube.com/")
        )
        var sped = false
        for _ in 0..<60 {
            sped = try await web.evaluateJavaScript(
                "document.getElementById('v')?.playbackRate === 10") as? Bool == true
            if sped { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(sped)
    }
}
