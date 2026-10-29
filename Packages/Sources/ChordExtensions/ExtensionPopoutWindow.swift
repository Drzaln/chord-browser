import AppKit
import Foundation
import WebKit

/// A `windows.create({ type: "popup" })` window showing the extension's own
/// page: a small window of the page, with a window id of its own, as Chrome
/// and Search open a password manager's vault or a passkey prompt.
///
/// Chord's extension "window" is otherwise a Space (ADR 011), and a requested
/// window became a tab there with the Space's id. Bitwarden keeps the id
/// `windows.create` returns and ends its passkey session when
/// `windows.onRemoved` names it — a tab carrying the Space's id gave it
/// neither, and every passkey request failed as "not allowed". Websites still
/// open as tabs: a popup of one would need the engine's tab machinery.
@MainActor
final class ExtensionPopoutWindow: NSObject, WKWebExtensionWindow, NSWindowDelegate,
    WKUIDelegate
{
    let spaceID: UUID
    private(set) weak var context: WKWebExtensionContext?
    private weak var controller: WKWebExtensionController?
    private weak var host: WebKitExtensionHost?
    private let window: NSWindow
    let web: WKWebView
    private(set) var page: PopoutPage!
    /// Told when the window has closed, so the host drops it.
    var onClosed: ((ExtensionPopoutWindow) -> Void)?

    init?(
        url: URL, frame asked: CGRect, context: WKWebExtensionContext,
        controller: WKWebExtensionController, host: WebKitExtensionHost, spaceID: UUID,
        focused: Bool
    ) {
        guard let configuration = context.webViewConfiguration else { return nil }
        self.spaceID = spaceID
        self.context = context
        self.controller = controller
        self.host = host
        let frame = Self.frame(asked: asked)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
        super.init()
        page = PopoutPage(owner: self)
        window.isReleasedWhenClosed = false
        window.title = context.webExtension.displayName ?? ""
        window.delegate = self
        web.uiDelegate = self
        web.autoresizingMask = [.width, .height]
        window.contentView = web
        web.load(URLRequest(url: url))

        controller.didOpenWindow(self)
        context.didOpenTab(page)
        if focused {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    /// The frame asked for, kept on a screen; without a usable one (parts
    /// left unset come as NaN, and AppKit traps on a frame made of them) the
    /// size asked for, or Chrome's popup size, in the middle of the screen.
    /// Ported from Search (`Extensions.onScreen`, `popupFrame`).
    static func frame(asked: CGRect) -> NSRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        let main = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let parts = [asked.minX, asked.minY, asked.width, asked.height]
        if !asked.isNull, parts.allSatisfy(\.isFinite), asked.width >= 200, asked.height >= 150 {
            let home = screens.max {
                $0.intersection(asked).area < $1.intersection(asked).area
            } ?? main
            var frame = asked
            frame.size.width = min(frame.width, home.width)
            frame.size.height = min(frame.height, home.height)
            let seen = screens.map { $0.intersection(frame) }.max { $0.area < $1.area } ?? .zero
            if seen.width < min(160, frame.width) || seen.height < min(120, frame.height) {
                frame.origin.x = min(max(frame.minX, home.minX), home.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, home.minY), home.maxY - frame.height)
            }
            return frame
        }
        let width = min(asked.width.isFinite && asked.width >= 200 ? asked.width : 380, main.width)
        let height = min(asked.height.isFinite && asked.height >= 150 ? asked.height : 600, main.height)
        return NSRect(
            x: main.midX - width / 2, y: main.midY - height / 2, width: width, height: height
        )
    }

    func close() { window.close() }

    var isKey: Bool { window.isKeyWindow }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        controller?.didFocusWindow(self)
    }

    func windowWillClose(_ notification: Notification) {
        context?.didCloseTab(page, windowIsClosing: true)
        controller?.didCloseWindow(self)
        web.stopLoading()
        onClosed?(self)
    }

    // MARK: - WKUIDelegate

    /// `window.close()` from the page.
    func webViewDidClose(_ webView: WKWebView) { close() }

    /// A link asking for a new window opens as a tab in the Space.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url {
            _ = host?.tabModel?.extensionCreateTab(url: url, inSpace: spaceID, active: true)
        }
        return nil
    }

    // MARK: - WKWebExtensionWindow

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [page] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { page }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .popup }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        window.isMiniaturized ? .minimized : .normal
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { window.frame }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        window.screen?.frame ?? NSScreen.main?.frame ?? .null
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext) async throws {
        window.setFrame(Self.frame(asked: frame), display: true)
    }

    func focus(for context: WKWebExtensionContext) async throws {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close(for context: WKWebExtensionContext) async throws { close() }
}

/// The popout's one page, as WebKit's tab.
@MainActor
final class PopoutPage: NSObject, WKWebExtensionTab {
    private weak var owner: ExtensionPopoutWindow?

    init(owner: ExtensionPopoutWindow) { self.owner = owner }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { 0 }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { owner?.web }
    func title(for context: WKWebExtensionContext) -> String? { owner?.web.title }
    func url(for context: WKWebExtensionContext) -> URL? { owner?.web.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(owner?.web.isLoading ?? false)
    }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
    func close(for context: WKWebExtensionContext) async throws { owner?.close() }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
