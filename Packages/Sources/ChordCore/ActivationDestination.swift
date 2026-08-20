import Foundation

/// Where an activated command bar result lands (4.4).
///
/// A three-way choice rather than a `forceNewTab` flag: the bar can be opened
/// to fill a *split* as well as a tab, and a Bool cannot say which of three
/// places a result belongs in.
///
/// In Core because the row's label depends on it — the same result reads
/// "Switch to Tab" or "Move to Split" depending on how the bar was opened, and
/// that text is decided by the same pure ranking code the tests exercise.
public enum ActivationDestination: Sendable, Equatable {
    /// `Cmd+L` — navigate the tab you are already on.
    case currentTab
    /// `Cmd+T`, the sidebar's New Tab, and `Cmd+Enter` from any mode.
    case newTab
    /// `Cmd+Shift+D` — a new pane beside the focused one (4.5).
    case newPane
}
