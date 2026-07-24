import BrowserCore
import Foundation
import Observation

/// Signals the reused command bar view that it is being shown again.
///
/// The panel and its SwiftUI view are built once and reused, so `onAppear`
/// fires exactly once in the app's lifetime. Without a token like this, the
/// second `Cmd+T` shows a bar that still holds the previous query and never
/// takes keyboard focus.
/// What Return does to the highlighted result, decided by which shortcut opened
/// the bar (4.4).
public enum CommandBarMode: Sendable {
    /// `Cmd+T` and the sidebar's New Tab — Return opens the result in a new tab.
    case newTab
    /// `Cmd+L` — Return navigates the tab you are already on.
    case currentTab
    /// `Cmd+Shift+D` — Return opens the result as a new pane beside the
    /// focused one (4.5). Same reasoning as `Cmd+T`: you are splitting in order
    /// to put something specific there, and a blank pane makes you type the
    /// destination afterwards anyway.
    case newPane

    /// Where Return sends the highlighted result.
    var destination: ActivationDestination {
        switch self {
        case .newTab: .newTab
        case .currentTab: .currentTab
        case .newPane: .newPane
        }
    }
}

@MainActor
@Observable
final class CommandBarSession {
    /// Incremented on every present. The view resets and focuses on change.
    private(set) var presentToken = 0

    /// Set by the shortcut that opened the bar, read when Return is pressed.
    private(set) var mode: CommandBarMode = .newTab

    /// Text the input should open pre-filled with, and select. Used when the
    /// sidebar address button opens the bar on the current URL (like Cmd+L in a
    /// conventional browser). Empty for an ordinary open.
    private(set) var initialQuery: String = ""

    /// Incremented when something outside the SwiftUI view asks for the
    /// highlighted result to be opened.
    private(set) var activateToken = 0
    private(set) var activateForcesNewTab = false

    func beginPresentation(mode: CommandBarMode, initialQuery: String = "") {
        self.mode = mode
        self.initialQuery = initialQuery
        presentToken += 1
    }

    /// Used by the panel's key-equivalent handling: a focused `TextField`
    /// swallows Return and ignores Cmd+Return outright, so Cmd+Enter has to be
    /// caught in AppKit and routed back into the view (4.4).
    func requestActivate(forceNewTab: Bool) {
        activateForcesNewTab = forceNewTab
        activateToken += 1
    }
}
