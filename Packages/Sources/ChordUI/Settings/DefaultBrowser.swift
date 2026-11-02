import AppKit
import ChordCore
import Observation
import os

private let log = Logger(subsystem: "com.rizal.chord", category: "default-browser")

/// The "Default browser" row's state: what macOS says now, and whether a
/// request to change it is waiting on the system's confirmation.
@MainActor
@Observable
final class DefaultBrowserModel {
    private(set) var isDefault: Bool
    /// True while macOS's "change your default web browser?" alert is up, so
    /// the button can't stack a second request behind it.
    private(set) var isAsking = false

    private let control: any DefaultBrowserControlling

    init(control: any DefaultBrowserControlling) {
        self.control = control
        isDefault = control.isDefault
    }

    /// Re-reads the system default. The user can change it in System Settings
    /// while Chord is in the background, so the row asks again on every show.
    func refresh() {
        isDefault = control.isDefault
    }

    /// Asks macOS, then reads back what it decided: choosing "Keep" in the
    /// system alert may throw or may quietly change nothing.
    func makeDefault() async {
        guard !isAsking else { return }
        isAsking = true
        defer { isAsking = false }
        do {
            try await control.makeDefault()
        } catch {
            // Declined or failed. Either way the read below shows the truth, but
            // the reason is logged: a silent failure here is otherwise invisible.
            log.error("make default failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
        log.notice("make default done, isDefault=\(self.isDefault, privacy: .public)")
    }
}

/// The real default-browser control, through `NSWorkspace`. No entitlement is
/// involved on macOS: declaring `http`/`https` URL types is what makes Chord a
/// candidate, and the system asks the user before any change.
@MainActor
final class WorkspaceDefaultBrowser: DefaultBrowserControlling {
    private static let schemes = ["http", "https"]

    var isDefault: Bool {
        Self.schemes.allSatisfy(Self.isHandledByChord)
    }

    /// Asks for `http` first: that request is the one that raises macOS's
    /// "change your default web browser?" alert, and accepting it normally
    /// carries `https` along. `https` is asked for only when `http` is now
    /// Chord's and `https` still isn't. Asking unconditionally could stack a
    /// second alert on the first, and asking after a "Keep Safari" would nag.
    func makeDefault() async throws {
        try await Self.request("http")
        guard Self.isHandledByChord("http") else {
            log.notice("http still not Chord after the request, not asking for https")
            return
        }
        if !Self.isHandledByChord("https") {
            try await Self.request("https")
        }
    }

    private static func request(_ scheme: String) async throws {
        log.notice(
            "asking macOS to open \(scheme, privacy: .public) with \(Bundle.main.bundlePath, privacy: .public)"
        )
        try await NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme
        )
    }

    /// By bundle id, not path: a DerivedData build and the copy in
    /// /Applications are the same app.
    private static func isHandledByChord(_ scheme: String) -> Bool {
        guard let ownID = Bundle.main.bundleIdentifier,
            let probe = URL(string: "\(scheme)://example.com"),
            let handler = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else { return false }
        return Bundle(url: handler)?.bundleIdentifier == ownID
    }
}
