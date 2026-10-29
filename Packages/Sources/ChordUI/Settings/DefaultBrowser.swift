import AppKit
import ChordCore
import Observation

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
            // Declined or failed. Either way the read below shows the truth.
        }
        refresh()
    }
}

/// The real default-browser control, through `NSWorkspace`. No entitlement is
/// involved on macOS: declaring `http`/`https` URL types is what makes Chord a
/// candidate, and the system asks the user before any change.
@MainActor
final class WorkspaceDefaultBrowser: DefaultBrowserControlling {
    private static let schemes = ["http", "https"]

    var isDefault: Bool {
        // By bundle id, not path: a DerivedData build and the copy in
        // /Applications are the same app.
        guard let ownID = Bundle.main.bundleIdentifier else { return false }
        return Self.schemes.allSatisfy { scheme in
            guard let probe = URL(string: "\(scheme)://example.com"),
                let handler = NSWorkspace.shared.urlForApplication(toOpen: probe)
            else { return false }
            return Bundle(url: handler)?.bundleIdentifier == ownID
        }
    }

    func makeDefault() async throws {
        for scheme in Self.schemes {
            try await NSWorkspace.shared.setDefaultApplication(
                at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme
            )
        }
    }
}
