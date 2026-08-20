import AppKit
import ChordCore
import ChordStore
import SwiftUI

/// The sleep timer entry in a tab's context menu (non-spec: user-requested).
///
/// A sleep timer pauses the tab's media after the chosen duration — the "stop
/// playing as I fall asleep" behaviour, aimed at YouTube and YouTube Music.
/// Presets replace the tab's existing timer; "Custom…" accepts any duration up
/// to 24 hours (see `parseMinutes`); a separate entry cancels one that is armed.
struct SleepTimerMenu: View {
    @Bindable var store: TabStore
    let tab: ChordCore.Tab

    private static let presets = [15, 30, 60, 90]

    /// The sleep timer's upper bound. A timer beyond a day is not a sleep timer.
    static let maxMinutes = 24 * 60

    /// The last accepted custom input, pre-filled next time the prompt opens so
    /// repeating a duration is one Return. Session-scoped only — this is not
    /// important enough to persist.
    private static var lastCustomText: String?

    var body: some View {
        Menu {
            ForEach(Self.presets, id: \.self) { minutes in
                Button("\(minutes) Minutes") {
                    store.setSleepTimer(minutes: minutes, tabID: tab.id)
                }
            }
            Divider()
            Button("Custom…") { promptForCustomMinutes() }
            if store.isSleepTimerArmed(tab.id) {
                Divider()
                Button("Cancel Sleep Timer") { store.cancelSleepTimer(tab.id) }
            }
        } label: {
            Text("Sleep Timer")
        }
    }

    /// Parses a duration string into minutes. Accepts "45", "90m", "2h",
    /// "1.5h", "2h30", and "1:30". A bare decimal ("1.5") is refused on
    /// purpose — it is ambiguous between 1.5 minutes and 1.5 hours, and the
    /// sleep timer must never guess which the user meant.
    static func parseMinutes(_ text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        let minutes: Double
        if s.contains(":") {
            let parts = s.split(separator: ":")
            guard parts.count == 2,
                let hours = Double(parts[0]),
                let remainder = Double(parts[1]),
                remainder < 60
            else { return nil }
            minutes = hours * 60 + remainder
        } else if let hIndex = s.firstIndex(of: "h") {
            guard let hours = Double(s[..<hIndex]) else { return nil }
            let rest = s[s.index(after: hIndex)...].replacingOccurrences(of: "m", with: "")
            var total = hours * 60
            if !rest.isEmpty {
                guard let extra = Double(rest) else { return nil }
                total += extra
            }
            minutes = total
        } else {
            let plain = s.hasSuffix("m") ? String(s.dropLast()) : s
            guard !plain.contains("."), let value = Int(plain) else { return nil }
            minutes = Double(value)
        }

        guard minutes.isFinite else { return nil }
        let rounded = Int(minutes.rounded())
        guard rounded >= 1, rounded <= maxMinutes else { return nil }
        return rounded
    }

    private func promptForCustomMinutes() {
        let alert = NSAlert()
        alert.messageText = "Sleep Timer"
        alert.informativeText = "Pause this tab's playback after how long?"
        alert.addButton(withTitle: "Set Timer")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Minutes — e.g. 45, 1:30, 1.5h"
        if let last = Self.lastCustomText { field.stringValue = last }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        // Stay in the prompt on bad input rather than silently dropping the
        // user's request.
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard let minutes = Self.parseMinutes(field.stringValue) else {
                NSSound.beep()
                continue
            }
            Self.lastCustomText = field.stringValue
            store.setSleepTimer(minutes: minutes, tabID: tab.id)
            return
        }
    }
}
