import ChordCore
import SwiftUI
import Testing

@testable import ChordUI

/// The text on any Space-tinted surface (a toast capsule, a selected sidebar
/// row, a picked command-bar row) is chosen from the colour that surface paints,
/// not from the raw accent. These pin the two rules that matter: pick the
/// higher-contrast of black/white, and keep at least AA contrast for small text.
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

    @Test("The Color overload clears AA for the tinted surfaces it feeds")
    func colorOverloadClearsAA() {
        let tints: [Color] = [
            Color(.sRGB, red: 0.95, green: 0.95, blue: 0.95, opacity: 1),
            Color(.sRGB, red: 0.06, green: 0.06, blue: 0.06, opacity: 1),
            Color(.sRGB, red: 0.66, green: 0.13, blue: 0.40, opacity: 1),
        ]
        for tint in tints {
            for dark in [false, true] {
                let contrast = SpaceTheme.toastLabelContrast(
                    on: tint, isDarkAppearance: dark, overlayOpacity: 0.40
                )
                #expect((contrast ?? 0) >= 4.5, "\(dark ? "dark" : "light") only \(contrast ?? -1):1")
                // And the pair the views actually use is available.
                #expect(
                    SpaceTheme.foregroundPair(
                        on: tint, isDarkAppearance: dark, overlayOpacity: 0.40
                    ) != nil
                )
            }
        }
    }

    @Test("The pair's primary is the higher-contrast of black/white")
    func pairPicksMaxContrast() {
        // A pale tint over light chrome paints a light surface, where dark text
        // wins — the exact case a fixed raw-accent threshold got wrong.
        let pale = Color(.sRGB, red: 0.95, green: 0.95, blue: 0.95, opacity: 1)
        let pair = SpaceTheme.foregroundPair(
            on: pale, isDarkAppearance: false, overlayOpacity: 0.40
        )
        #expect(pair?.primary == Color.black.opacity(0.88))
    }
}
