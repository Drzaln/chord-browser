import ChordCore
import Testing

@testable import ChordUI

/// The toast's label colour is chosen from the capsule it is painted on — the
/// Space accent at 0.4 over the material, approximated per appearance. These pin
/// the two rules that matter: pick the higher-contrast of black/white, and keep
/// at least AA contrast for the 12pt label.
@Suite("Toast text contrast")
@MainActor
struct ToastTextContrastTests {

    @Test("A light Space gets dark text, a dark Space gets light")
    func extremes() {
        #expect(SpaceTheme.prefersDarkText(accent: "#F5F5F5", isDarkAppearance: false))
        #expect(!SpaceTheme.prefersDarkText(accent: "#101010", isDarkAppearance: true))
    }

    @Test("A dark Space over light chrome stays light, so dark text")
    func darkAccentOnLightChrome() {
        // At 0.4 the accent is over half material: an almost-black Space on a
        // light window still paints a light capsule, where white text would be
        // weak. The old raw-accent rule read the accent alone and got this wrong.
        #expect(SpaceTheme.prefersDarkText(accent: "#101010", isDarkAppearance: false))
    }

    @Test("A pale Space over dark chrome takes white text")
    func paleAccentOnDarkChrome() {
        // Mirror case: the pale accent over a near-black base still lands dark
        // enough that white text wins.
        #expect(!SpaceTheme.prefersDarkText(accent: "#E8E8E8", isDarkAppearance: true))
    }

    @Test("A mid-tone Space takes the higher-contrast side, not a fixed threshold")
    func midTonePicksMaxContrast() {
        // Around the crossover the choice must still be the stronger one; assert
        // it via the ratio rather than hardcoding which colour.
        let mid: ColorHex = "#9AA0A6"
        for dark in [false, true] {
            let contrast = SpaceTheme.toastLabelContrast(accent: mid, isDarkAppearance: dark)
            #expect(contrast >= 4.5, "mid-tone \(dark ? "dark" : "light") only \(contrast):1")
        }
    }

    @Test("Every label choice clears AA (≥4.5:1) against the painted capsule")
    func alwaysAA() {
        // A spread of hues and lightnesses, in both appearances.
        let accents: [ColorHex] = [
            "#000000", "#333333", "#7A7A7A", "#B0B0B0", "#FFFFFF",
            "#E91E63", "#4CAF50", "#2196F3", "#FFC107", "#9C27B0",
        ]
        for accent in accents {
            for dark in [false, true] {
                let contrast = SpaceTheme.toastLabelContrast(accent: accent, isDarkAppearance: dark)
                #expect(contrast >= 4.5, "\(accent) \(dark ? "dark" : "light") only \(contrast):1")
            }
        }
    }
}
