import AppKit
import Foundation
import SwiftUI

/// An opaque, renderable web surface.
///
/// This is the entire vocabulary `BrowserUI` has for web content: it can place
/// one in a view tree and nothing else. `WKWebView` never crosses this line.
public struct AnyWebSurface: View, Identifiable, Equatable {
    public let id: UUID
    private let container: NSView

    init(id: UUID, container: NSView) {
        self.id = id
        self.container = container
    }

    /// Pane identity is the whole story: a pane has exactly one container for
    /// its lifetime, so comparing views would add main-actor isolation to an
    /// operation SwiftUI wants to run anywhere.
    nonisolated public static func == (lhs: AnyWebSurface, rhs: AnyWebSurface) -> Bool {
        lhs.id == rhs.id
    }

    /// A surface backed by an empty view, so fakes can satisfy `WebEngine`
    /// without WebKit. Renders nothing; not for production use.
    @MainActor
    public static func empty(id: UUID) -> AnyWebSurface {
        AnyWebSurface(id: id, container: NSView())
    }

    public var body: some View {
        WebSurfaceRepresentable(container: container)
            .id(id)
    }
}

/// Hands SwiftUI the *same* container view every update. Rebuilding it would
/// tear down and reload the page on unrelated state changes.
private struct WebSurfaceRepresentable: NSViewRepresentable {
    let container: NSView

    func makeNSView(context: Context) -> NSView { container }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Clips web content to the inset card's rounded corners.
///
/// Known trap (BROWSER_SPEC 5): setting `cornerRadius` + `masksToBounds`
/// directly on a `WKWebView` produces artifacts and can drop the compositor
/// fast path. The clip belongs on this plain container; the card's shadow is
/// drawn by a sibling layer in the UI package, never here.
final class WebSurfaceContainerView: NSView {
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unimplemented: init(coder:)") }

    func install(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func removeContent() {
        subviews.forEach { $0.removeFromSuperview() }
    }
}
