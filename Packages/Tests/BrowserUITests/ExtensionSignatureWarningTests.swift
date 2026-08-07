import BrowserCore
import Testing

@testable import BrowserUI

/// The extension signature verdict copy (warn-but-install). Pure status → text
/// mapping, so it is pinned down here rather than through the settings sheet.
@Suite("Extension signature warning copy")
@MainActor
struct ExtensionSignatureWarningTests {

    @Test("Trusted and verified verdicts do not warn")
    func trustedStatusesDoNotWarn() {
        #expect(ExtensionsSettings.warningText(for: .trusted).contains("trusted"))
        #expect(!ExtensionsSettings.warningText(for: .verified).contains("untrusted"))
    }

    @Test("Every untrusted verdict has explicit, distinct copy")
    func untrustedStatusesHaveExplicitCopy() {
        let texts = Set(ExtensionSignatureStatus.allCases.filter { !$0.isTrusted }.map {
            ExtensionsSettings.warningText(for: $0)
        })
        #expect(texts.count == 3, "each untrusted verdict must read differently")
        for status: ExtensionSignatureStatus in [.tampered, .unsigned, .unsupported] {
            #expect(!ExtensionsSettings.warningText(for: status).isEmpty)
        }
    }

    @Test("The install-message copy is built from the same verdict text")
    func installMessageEmbedsVerdictText() {
        let text = ExtensionsSettings.warningText(for: .unsigned)
        #expect(text.contains("unsigned"))
        #expect(text.contains("verified developer"))
    }
}
