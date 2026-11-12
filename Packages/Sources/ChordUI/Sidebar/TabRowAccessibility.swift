/// What VoiceOver's Actions menu offers on a sidebar tab row (gn0.9).
///
/// The row's close button exists only while the pointer hovers (Arc's
/// behaviour, kept on purpose), and VoiceOver never hovers. So the same
/// commands are published as named accessibility actions, which change
/// nothing on screen.
enum TabRowAccessibilityAction: Equatable {
    case close
    case mute
    case unmute
    case cancelSleepTimer

    var name: String {
        switch self {
        case .close: "Close Tab"
        case .mute: "Mute Tab"
        case .unmute: "Unmute Tab"
        case .cancelSleepTimer: "Cancel Sleep Timer"
        }
    }

    /// The actions for a row in this state, in menu order. Mirrors which
    /// buttons the row shows: mute only while the tab is audible or muted,
    /// the sleep timer only while one is armed, close always.
    static func actions(
        isPlayingAudio: Bool, isMuted: Bool, hasSleepTimer: Bool
    ) -> [TabRowAccessibilityAction] {
        var actions: [TabRowAccessibilityAction] = []
        if isMuted {
            actions.append(.unmute)
        } else if isPlayingAudio {
            actions.append(.mute)
        }
        if hasSleepTimer { actions.append(.cancelSleepTimer) }
        actions.append(.close)
        return actions
    }
}
