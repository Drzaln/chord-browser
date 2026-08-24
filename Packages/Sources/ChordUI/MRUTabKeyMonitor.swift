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
/// The switcher overlay appears only when Ctrl is *held*, not on a quick tap:
/// Ctrl going down arms a short hold timer, and the session (and overlay) begin
/// only if Ctrl is still down when it fires (~250 ms). A Tab press before that
/// is a plain quick switch to the neighbouring tab — no overlay flash — which
/// is the standard browser UX. Holding Ctrl and pressing Tab repeatedly walks
/// the list once the session is up; releasing Ctrl commits; a bare Ctrl hold
/// (no Tab) selects nothing.
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
    /// Fires when Ctrl has been held past the quick-tap threshold; it is what
    /// turns a held Ctrl into the switcher session instead of a one-shot switch.
    private var holdTask: Task<Void, Never>?

    private static let holdThreshold = Duration.milliseconds(250)

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
        holdTask?.cancel()
        holdTask = nil
        NotificationCenter.default.removeObserver(self)
    }

    /// The window stopped being key mid-session — Ctrl is still held, but the
    /// next key events belong to a different window, so the release would never
    /// commit here. Abandon without selecting, and forget the held Ctrl so a
    /// later Tab in *this* window is not mistaken for Ctrl+Tab.
    @objc private func windowDidResignKey(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === self.window else { return }
        controlDown = false
        holdTask?.cancel()
        holdTask = nil
        store.cancelMRUSwitch(in: windowState)
    }

    /// Arms the hold timer that opens the switcher if Ctrl stays down. A quick
    /// tap releases Ctrl first and the timer dies before it fires.
    private func armHoldTimer() {
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: Self.holdThreshold)
            guard !Task.isCancelled, controlDown, !windowState.isMRUSessionPresented else { return }
            store.beginMRUSwitch(in: windowState)
        }
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
                controlDown = true
                armHoldTimer()
            } else if !ctrl && controlDown {
                holdTask?.cancel()
                holdTask = nil
                // A session only exists when Ctrl was held past the threshold;
                // a quick tap already switched on the Tab press and has nothing
                // to commit here.
                if windowState.isMRUSessionPresented {
                    store.commitMRUSwitch(in: windowState)
                }
                controlDown = false
            }
        case .keyDown:
            // Ctrl+Tab / Ctrl+Shift+Tab. Consumed so neither the web view nor
            // the menu's key equivalent can eat it; `selectNextTab`/`selectPreviousTab`
            // step an open session or, with none, switch immediately.
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