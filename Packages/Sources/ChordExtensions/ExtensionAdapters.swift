import Foundation
import WebKit

/// Presents a Space as a `WKWebExtensionWindow` to its per-Space controller
/// (7.3b). One window per Space: extensions are per-Space (ADR 011), so the
/// controller sees exactly its Space's tabs and no others.
///
/// It ignores the `context` argument on purpose — every extension loaded in the
/// Space shares the same tab set, so the adapter's stored `spaceID` is the whole
/// answer.
@MainActor
final class ExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    let spaceID: UUID
    private weak var host: WebKitExtensionHost?

    init(spaceID: UUID, host: WebKitExtensionHost) {
        self.spaceID = spaceID
        self.host = host
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let host, let model = host.tabModel else { return [] }
        return model.extensionTabs(inSpace: spaceID).map { host.tabAdapter(for: $0.id, inSpace: spaceID) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let host, let model = host.tabModel,
            let active = model.extensionActiveTab(inSpace: spaceID)
        else { return nil }
        return host.tabAdapter(for: active.id, inSpace: spaceID)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        host?.isSpacePrivate(spaceID) ?? false
    }
}

/// Presents one of the app's tabs as a `WKWebExtensionTab`. Per (Space, tab);
/// the host caches these so WebKit sees a stable object identity for a tab.
///
/// The mapping is close to one-to-one onto `TabStore` + engine calls, reached
/// through the WebKit-free `ExtensionTabModel`. The single WebKit-typed piece is
/// `webView(for:)`, served by the engine's `PaneWebViewProviding`.
@MainActor
final class ExtensionTabAdapter: NSObject, WKWebExtensionTab {
    let tabID: UUID
    let spaceID: UUID
    private weak var host: WebKitExtensionHost?

    init(tabID: UUID, spaceID: UUID, host: WebKitExtensionHost) {
        self.tabID = tabID
        self.spaceID = spaceID
        self.host = host
    }

    private var snapshot: ExtensionTabSnapshot? {
        host?.tabModel?.extensionTab(tabID)
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        host?.windowAdapter(forSpace: spaceID)
    }

    func url(for context: WKWebExtensionContext) -> URL? { snapshot?.url }

    func title(for context: WKWebExtensionContext) -> String? { snapshot?.title }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        snapshot?.isSelected ?? false
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        snapshot?.index ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        guard let paneID = snapshot?.focusedPaneID else { return nil }
        return host?.paneWebViewProvider?.paneWebView(paneID)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (((any Error)?) -> Void)) {
        host?.tabModel?.extensionActivateTab(tabID)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (((any Error)?) -> Void)) {
        host?.tabModel?.extensionLoadURL(url, inTab: tabID)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (((any Error)?) -> Void)) {
        host?.tabModel?.extensionReloadTab(tabID, fromOrigin: fromOrigin)
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (((any Error)?) -> Void)) {
        host?.tabModel?.extensionGoBack(inTab: tabID)
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (((any Error)?) -> Void)) {
        host?.tabModel?.extensionGoForward(inTab: tabID)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (((any Error)?) -> Void)) {
        host?.tabModel?.extensionCloseTab(tabID)
        completionHandler(nil)
    }
}
