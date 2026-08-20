import ChordCore
import ChordEngine
import Foundation
import Testing
import WebKit

@testable import ChordExtensions

/// A fake tab model recording the actions the adapters drive.
@MainActor
private final class FakeTabModel: ExtensionTabModel {
    var snapshots: [ExtensionTabSnapshot] = []
    var activatedTab: UUID?
    var loadedURLs: [(UUID, URL)] = []
    var reloaded: [(UUID, Bool)] = []
    var wentBack: [UUID] = []
    var wentForward: [UUID] = []
    var closed: [UUID] = []

    func extensionTabs(inSpace spaceID: UUID) -> [ExtensionTabSnapshot] {
        snapshots.filter { $0.spaceID == spaceID }
    }
    func extensionActiveTab(inSpace spaceID: UUID) -> ExtensionTabSnapshot? {
        snapshots.first { $0.spaceID == spaceID && $0.isSelected }
    }
    func extensionTab(_ tabID: UUID) -> ExtensionTabSnapshot? {
        snapshots.first { $0.id == tabID }
    }
    func extensionActivateTab(_ tabID: UUID) { activatedTab = tabID }
    func extensionLoadURL(_ url: URL, inTab tabID: UUID) { loadedURLs.append((tabID, url)) }
    func extensionReloadTab(_ tabID: UUID, fromOrigin: Bool) { reloaded.append((tabID, fromOrigin)) }
    func extensionGoBack(inTab tabID: UUID) { wentBack.append(tabID) }
    func extensionGoForward(inTab tabID: UUID) { wentForward.append(tabID) }
    func extensionCloseTab(_ tabID: UUID) { closed.append(tabID) }
}

@MainActor
struct ExtensionAdapterTests {
    private func makeContext() async throws -> WKWebExtensionContext {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{ "manifest_version": 3, "name": "X", "version": "1" }"#
            .data(using: .utf8)!.write(to: dir.appending(path: "manifest.json"))
        // A context needs an extension; a synthetic MV3 dir is enough. The tab
        // adapters ignore the context argument, so any valid one serves.
        let ext = try #require(await loadExtension(dir))
        return WKWebExtensionContext(for: ext)
    }
    private func loadExtension(_ url: URL) async -> WKWebExtension? {
        try? await WKWebExtension(resourceBaseURL: url)
    }

    private func snap(_ id: UUID, space: UUID, url: String, selected: Bool, index: Int)
        -> ExtensionTabSnapshot
    {
        ExtensionTabSnapshot(
            id: id, spaceID: space, focusedPaneID: UUID(),
            url: URL(string: url), title: "t", isSelected: selected, index: index
        )
    }

    @Test func windowExposesTheSpacesTabsAndActiveTab() async throws {
        let host = WebKitExtensionHost()
        let model = FakeTabModel()
        host.tabModel = model
        let space = UUID()
        let a = UUID(), b = UUID()
        model.snapshots = [
            snap(a, space: space, url: "https://a.test", selected: false, index: 0),
            snap(b, space: space, url: "https://b.test", selected: true, index: 1),
        ]
        let context = try await makeContext()

        let window = host.windowAdapter(forSpace: space)
        let tabs = window.tabs(for: context).compactMap { $0 as? ExtensionTabAdapter }
        #expect(tabs.map(\.tabID) == [a, b])
        #expect((window.activeTab(for: context) as? ExtensionTabAdapter)?.tabID == b)
        #expect(window.windowType(for: context) == .normal)
    }

    @Test func tabAdapterReflectsTheSnapshot() async throws {
        let host = WebKitExtensionHost()
        let model = FakeTabModel()
        host.tabModel = model
        let space = UUID()
        let a = UUID()
        model.snapshots = [snap(a, space: space, url: "https://a.test", selected: true, index: 3)]
        let context = try await makeContext()

        let tab = host.tabAdapter(for: a, inSpace: space)
        #expect(tab.url(for: context) == URL(string: "https://a.test"))
        #expect(tab.isSelected(for: context) == true)
        #expect(tab.indexInWindow(for: context) == 3)
        #expect((tab.window(for: context) as? ExtensionWindowAdapter)?.spaceID == space)
    }

    @Test func tabActionsDriveTheModel() async throws {
        let host = WebKitExtensionHost()
        let model = FakeTabModel()
        host.tabModel = model
        let space = UUID()
        let a = UUID()
        model.snapshots = [snap(a, space: space, url: "https://a.test", selected: true, index: 0)]
        let context = try await makeContext()
        let tab = host.tabAdapter(for: a, inSpace: space)

        tab.activate(for: context) { _ in }
        tab.loadURL(URL(string: "https://x.test")!, for: context) { _ in }
        tab.reload(fromOrigin: true, for: context) { _ in }
        tab.goBack(for: context) { _ in }
        tab.goForward(for: context) { _ in }
        tab.close(for: context) { _ in }

        #expect(model.activatedTab == a)
        #expect(model.loadedURLs.map(\.0) == [a])
        #expect(model.reloaded.first?.1 == true)
        #expect(model.wentBack == [a])
        #expect(model.wentForward == [a])
        #expect(model.closed == [a])
    }

    @Test func adaptersAreCachedForStableIdentity() {
        let host = WebKitExtensionHost()
        let space = UUID()
        let a = UUID()
        // WebKit relies on object identity for tabs/windows, so the host must
        // hand back the same adapter each time.
        #expect(host.windowAdapter(forSpace: space) === host.windowAdapter(forSpace: space))
        #expect(host.tabAdapter(for: a, inSpace: space) === host.tabAdapter(for: a, inSpace: space))
    }

    @Test func webViewComesFromThePaneProvider() async throws {
        let host = WebKitExtensionHost()
        let model = FakeTabModel()
        host.tabModel = model
        let space = UUID()
        let paneID = UUID()
        let tabID = UUID()
        model.snapshots = [
            ExtensionTabSnapshot(
                id: tabID, spaceID: space, focusedPaneID: paneID,
                url: nil, title: "", isSelected: true, index: 0
            )
        ]
        let provider = FakePaneWebViewProvider()
        let webView = WKWebView()
        provider.views[paneID] = webView
        host.paneWebViewProvider = provider
        let context = try await makeContext()

        let tab = host.tabAdapter(for: tabID, inSpace: space)
        #expect(tab.webView(for: context) === webView)
    }
}

@MainActor
private final class FakePaneWebViewProvider: PaneWebViewProviding {
    var views: [UUID: WKWebView] = [:]
    func paneWebView(_ paneID: UUID) -> WKWebView? { views[paneID] }
}
