import AppKit
import ChordCore
import ChordStore
import SwiftUI

/// The Arc-style Ctrl+Tab MRU switcher's trigger: watches the Ctrl key and the
/// Tab key, and owns the whole interaction.
///
/// Stepping is handled *here*, not by the `Next Tab` / `Previous Tab` menu
/// commands (which remain as the visible binding and a click/fallback path): a
/// local monitor sees every keyDown before AppKit's key-equivalent matching,
/// so the menu's `.keyboardShortcut(.tab, modifiers: .control)` can be
/// swallowed by a first responder (the web view, a focused field) or by
/// full-keyboard-access navigation — the "sometimes Ctrl+Tab just does
/// nothing" failure. Consuming Tab here makes the interaction deterministic.
///
/// The monitor owns the two edges too: the overlay appears the moment Ctrl goes
/// down and the selection commits the moment it comes back up. A quick Ctrl+Tab
/// tap therefore lands on the most recent tab (the Tab press arms the commit,
/// release performs it), holding Ctrl and pressing Tab repeatedly walks the
/// list, and a bare Ctrl tap selects nothing.
///
/// Any other key while the overlay is up abandons the session so the key keeps
/// its normal meaning; the window resigning key does the same.
@MainActor
final class MRUTabKeyMonitor: NSObject {
    private let store: TabStore
    private let windowState: WindowState

    /// The window this monitor's key events belong to. Only the key window's
    /// monitor acts — the other windows' monitors ignore the same events.
    weak var window: NSWindow?

    private var monitor: Any?
    private var controlDown = false

    init(store: TabStore, windowState: WindowState) {
        self.store = store
        self.windowState = windowState
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil
        )
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self)
    }

    /// The window stopped being key mid-session — Ctrl is still held, but the
    /// next key events belong to a different window, so the release would never
    /// commit here. Abandon without selecting, and forget the held Ctrl so a
    /// later Tab in *this* window is not mistaken for Ctrl+Tab.
    @objc private func windowDidResignKey(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === self.window else { return }
        controlDown = false
        store.cancelMRUSwitch(in: windowState)
    }

    /// Returns true when the event was consumed (the overlay owns it) and must
    /// not reach anything else.
    ///
    /// Stepping is handled *here*, not by the menu commands, because a local
    /// monitor sees every keyDown before AppKit's key-equivalent matching — the
    /// menu's `.keyboardShortcut(.tab, modifiers: .control)` can be swallowed by
    /// a first responder (the web view, a focused field) or full-keyboard-access
    /// navigation, which is exactly the "sometimes Ctrl+Tab just does nothing"
    /// failure. The menu items stay as the visible binding and a fallback; the
    /// monitor consumes Tab the moment Ctrl is down, so only one path fires.
    private func handle(_ event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true else { return false }
        switch event.type {
        case .flagsChanged:
            let ctrl = event.modifierFlags.contains(.control)
            if ctrl && !controlDown {
                store.beginMRUSwitch(in: windowState)
            } else if !ctrl && controlDown {
                store.commitMRUSwitch(in: windowState)
            }
            controlDown = ctrl
        case .keyDown:
            // Ctrl+Tab / Ctrl+Shift+Tab. Consumed so neither the web view nor
            // the menu's key equivalent can eat it; `selectNextTab`/`selectPreviousTab`
            // step the session or, with no session, switch immediately.
            // 48 is kVK_Tab (the physical Tab key).
            if controlDown, event.keyCode == 48 {
                if event.modifierFlags.contains(.shift) {
                    store.selectPreviousTab(in: windowState)
                } else {
                    store.selectNextTab(in: windowState)
                }
                return true
            }
            // Any other key while the overlay is up abandons the session but
            // keeps its normal meaning — Cmd+1, say, still switches Space.
            if windowState.isMRUSessionPresented {
                store.cancelMRUSwitch(in: windowState)
            }
        default:
            break
        }
        return false
    }
}