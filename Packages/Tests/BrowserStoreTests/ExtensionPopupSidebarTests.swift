import BrowserCore
import Foundation
import Testing

@testable import BrowserStore

/// An extension popup must hold a revealed sidebar open while it is on screen.
///
/// The popup is an `NSPopover` anchored to the sidebar-header button, so a
/// sidebar that auto-hides mid-use takes the anchor out of the window and AppKit
/// closes the popup with it. Worse, moving the pointer into the popup is exactly
/// what ends the hover keeping the sidebar revealed — so with a collapsed sidebar
/// the popup closed the instant you reached for it, which is how Bitwarden's
/// unlock screen turned out to be unusable.
///
/// The AppKit half (anchor, popover delegate, the notification the view filters
/// on) cannot be reached from `swift test`; what is testable, and what actually
/// decides the behaviour, is the hold-open rule itself.
@Suite("Extension popup holds the sidebar open")
@MainActor
struct ExtensionPopupSidebarTests {

    private func makeWindowState() -> WindowState {
        WindowState(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @Test("A window with nothing happening does not hold its sidebar open")
    func idleWindowDoesNotHold() {
        let window = makeWindowState()
        #expect(window.isSidebarHeldOpen == false)
    }

    @Test("An open extension popup holds the sidebar open")
    func popupHolds() {
        let window = makeWindowState()
        window.isExtensionPopupOpen = true
        #expect(window.isSidebarHeldOpen)
    }

    @Test("Closing the popup releases the sidebar so auto-hide resumes")
    func closingReleases() {
        let window = makeWindowState()
        window.isExtensionPopupOpen = true
        window.isExtensionPopupOpen = false
        #expect(window.isSidebarHeldOpen == false)
    }

    @Test("The popup does not mask another reason to stay open")
    func otherHoldsStillApply() {
        let window = makeWindowState()
        window.isSidebarResizing = true
        window.isExtensionPopupOpen = true
        window.isExtensionPopupOpen = false
        // The resize drag is still in progress, so the sidebar stays.
        #expect(window.isSidebarHeldOpen)
    }

    @Test("A popup is window state, so a second window is unaffected")
    func popupIsPerWindow() {
        let first = makeWindowState()
        let second = makeWindowState()
        first.isExtensionPopupOpen = true
        #expect(first.isSidebarHeldOpen)
        #expect(second.isSidebarHeldOpen == false)
    }
}
