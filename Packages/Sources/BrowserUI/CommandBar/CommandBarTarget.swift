import BrowserStore
import Observation

/// Which window the (single, reused) command bar panel is acting for.
///
/// The panel is built once — rebuilding it per invocation blows the 50 ms
/// open-to-input-ready budget in 6.1 — so the window it targets cannot be a
/// stored property of the view. This box is set on every presentation and read
/// by `CommandBarView` when it activates a suggestion.
@MainActor
@Observable
public final class CommandBarTarget {
    public var windowState: WindowState?
    public init() {}
}
