@testable import ChordUI
import Testing

/// gn0.9: the hover-only close button is unreachable with VoiceOver, so the
/// row publishes its commands as named actions.
@Suite struct TabRowAccessibilityTests {
    @Test func aQuietRowOffersOnlyClose() {
        #expect(TabRowAccessibilityAction.actions(
            isPlayingAudio: false, isMuted: false, hasSleepTimer: false
        ) == [.close])
    }

    @Test func anAudibleRowOffersMute() {
        #expect(TabRowAccessibilityAction.actions(
            isPlayingAudio: true, isMuted: false, hasSleepTimer: false
        ) == [.mute, .close])
    }

    @Test func aMutedRowOffersUnmuteEvenWhenSilent() {
        #expect(TabRowAccessibilityAction.actions(
            isPlayingAudio: false, isMuted: true, hasSleepTimer: false
        ) == [.unmute, .close])
        #expect(TabRowAccessibilityAction.actions(
            isPlayingAudio: true, isMuted: true, hasSleepTimer: false
        ) == [.unmute, .close])
    }

    @Test func anArmedSleepTimerCanBeCancelled() {
        #expect(TabRowAccessibilityAction.actions(
            isPlayingAudio: true, isMuted: false, hasSleepTimer: true
        ) == [.mute, .cancelSleepTimer, .close])
    }

    @Test func namesAreWhatVoiceOverReads() {
        #expect(TabRowAccessibilityAction.close.name == "Close Tab")
        #expect(TabRowAccessibilityAction.cancelSleepTimer.name == "Cancel Sleep Timer")
    }
}
