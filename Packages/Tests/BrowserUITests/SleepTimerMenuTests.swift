import Testing

@testable import BrowserUI

/// The sleep timer's "Custom…" duration parser (non-spec: user-requested).
/// Pure string → minutes logic, so it is pinned down here rather than through
/// the alert prompt that uses it.
@Suite("Sleep timer duration parsing")
struct SleepTimerMenuTests {

    @Test("Plain numbers are minutes")
    func plainNumbersAreMinutes() {
        #expect(SleepTimerMenu.parseMinutes("45") == 45)
        #expect(SleepTimerMenu.parseMinutes("90m") == 90)
        #expect(SleepTimerMenu.parseMinutes(" 45 ") == 45)
        #expect(SleepTimerMenu.parseMinutes("0:45") == 45)
    }

    @Test("Hours forms are accepted")
    func hourForms() {
        #expect(SleepTimerMenu.parseMinutes("2h") == 120)
        #expect(SleepTimerMenu.parseMinutes("1.5h") == 90)
        #expect(SleepTimerMenu.parseMinutes("2h30") == 150)
        #expect(SleepTimerMenu.parseMinutes("2h30m") == 150)
        #expect(SleepTimerMenu.parseMinutes("1:30") == 90)
    }

    @Test("A bare decimal is refused as ambiguous, never guessed at")
    func refusesBareDecimals() {
        #expect(SleepTimerMenu.parseMinutes("1.5") == nil)
        #expect(SleepTimerMenu.parseMinutes("0.5") == nil)
    }

    @Test("Out-of-range and garbage input is refused")
    func refusesInvalidInput() {
        #expect(SleepTimerMenu.parseMinutes("") == nil)
        #expect(SleepTimerMenu.parseMinutes("abc") == nil)
        #expect(SleepTimerMenu.parseMinutes("0") == nil)
        #expect(SleepTimerMenu.parseMinutes("0h") == nil)
        #expect(SleepTimerMenu.parseMinutes("-30") == nil)
        #expect(SleepTimerMenu.parseMinutes("2:75") == nil)
        #expect(SleepTimerMenu.parseMinutes("1440") == 1440)
        #expect(SleepTimerMenu.parseMinutes("1441") == nil)
    }
}
