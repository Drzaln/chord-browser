import ChordTestSupport
import Foundation
import Testing
import WebKit

@testable import ChordEngine

/// c1k.8: what every tab carries, held to PerfBudget so it can't creep back.
@Suite("Perf budget: page scripts", .serialized)
@MainActor
struct PerfBudgetTests {

    private func defaultScripts() -> [WKUserScript] {
        let engine = WebKitEngine(
            configuration: EngineConfiguration(
                faviconCacheDirectory: URL(fileURLWithPath: "/tmp/engine-tests")
            )
        )
        return engine.makeContentController().userScripts
    }

    @Test("A default tab's user scripts: how many, how many in every frame, how big")
    func scriptBudget() {
        let scripts = defaultScripts()
        #expect(scripts.count <= PerfBudget.userScripts, "\(scripts.count) scripts: \(PerfBudget.failure)")
        let everyFrame = scripts.filter { !$0.isForMainFrameOnly }.count
        #expect(everyFrame <= PerfBudget.everyFrameScripts, "\(everyFrame) every-frame scripts: \(PerfBudget.failure)")
        let bytes = scripts.reduce(0) { $0 + $1.source.utf8.count }
        #expect(bytes <= PerfBudget.userScriptBytes, "\(bytes) bytes of scripts: \(PerfBudget.failure)")
    }

    @Test("A hidden tab's timers spread further apart the longer it stays hidden, as in Safari")
    func hiddenTimerThrottlingIncreases() {
        let preferences = WebKitEngine.configurationTemplate.preferences
        #expect(preferences.value(forKey: "hiddenPageDOMTimerThrottlingAutoIncreases") as? Bool == true)
        #expect(preferences.value(forKey: "hiddenPageDOMTimerThrottlingEnabled") as? Bool == true)
    }

    @Test("Page scripts set no repeating timer beyond the reviewed ones")
    func reviewedIntervalsOnly() {
        let scripts: [(String, String)] = [
            ("MediaActivityMonitor", MediaActivityMonitor.makeUserScript().source),
            ("ContextLinkMonitor", ContextLinkMonitor.makeUserScript().source),
            ("ContextImageMonitor", ContextImageMonitor.makeUserScript().source),
            ("AudioMuteController", AudioMuteController.makeUserScript().source),
            ("SleepTimerController", SleepTimerController.makeUserScript().source),
            ("NotificationBridge", NotificationBridge.makeUserScript().source),
            ("ScreenShareMonitor", ScreenShareMonitor.makeUserScript().source),
            ("YouTubeAdBlocker", YouTubeAdBlocker.makeUserScript().source),
            ("GeolocationBridge", GeolocationBridge.makeUserScript().source),
            ("PictureInPictureMonitor", PictureInPictureMonitor.makeUserScript().source),
            ("ChromeWebStoreRelay", ChromeWebStoreRelay.makeUserScript().source),
            ("PasswordFormMonitor", PasswordFormMonitor.makeUserScript().source),
        ]
        for (name, source) in scripts {
            let found = source.components(separatedBy: "setInterval(").count - 1
            let allowed = PerfBudget.reviewedIntervals[name]?.count ?? 0
            #expect(found <= allowed, "\(name) has \(found) setInterval, \(allowed) reviewed: \(PerfBudget.failure)")
        }
    }

    @Test("Two seconds after load, a plain page has no timer of Chord's running; YouTube one")
    func liveIntervals() async throws {
        #expect(try await liveIntervals(at: "https://example.com/") <= PerfBudget.intervalsOnAPlainPage,
                "\(PerfBudget.failure)")
        #expect(try await liveIntervals(at: "https://www.youtube.com/") <= PerfBudget.intervalsOnYouTube,
                "\(PerfBudget.failure)")
    }

    /// Chord's scripts in a page, after one that counts intervals set and
    /// not cleared.
    private func liveIntervals(at base: String) async throws -> Int {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: """
                window.__live = new Set();
                const set = window.setInterval, clear = window.clearInterval;
                window.setInterval = function () { const id = set.apply(this, arguments); window.__live.add(id); return id; };
                window.clearInterval = function (id) { window.__live.delete(id); return clear.call(this, id); };
                """,
            injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        for script in defaultScripts() { controller.addUserScript(script) }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.loadHTMLString(
            #"<div class="html5-video-player"><video></video></div><p>Page</p>"#,
            baseURL: URL(string: base)
        )
        for _ in 0..<60 where web.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .seconds(2))
        return try await web.evaluateJavaScript("window.__live.size") as? Int ?? 99
    }
}
