import ChordCore
import Foundation
import Testing

@testable import ChordEngine

/// The generated scripts for site overrides (ADR 024). The web view is WebKit's
/// business; what is checked here is that the text carries the host guard, the
/// CSS, and the user JS — and that an empty set produces nothing at all.
@Suite("Site override injection")
struct SiteOverrideInjectorTests {

    @Test("No enabled override means no scripts")
    @MainActor
    func noScriptWhenEmpty() {
        #expect(SiteOverrideInjector.makeUserScripts(overrides: []).isEmpty)
        #expect(
            SiteOverrideInjector.makeUserScripts(
                overrides: [SiteOverride(pattern: "example.com", isEnabled: false)]
            ).isEmpty
        )
        #expect(
            SiteOverrideInjector.makeUserScripts(
                overrides: [SiteOverride(pattern: "a.com")]
            ).isEmpty
        )
    }

    @Test("CSS and JS go in separate scripts, both document-start")
    @MainActor
    func scriptStructure() {
        let scripts = SiteOverrideInjector.makeUserScripts(
            overrides: [
                SiteOverride(
                    pattern: "example.com", css: "body { color: red; }", js: "document.title = 'x';"
                )
            ]
        )
        // Two scripts, not one: a syntax error in the user JS must not stop the
        // CSS from parsing (which is what inlining both would do).
        #expect(scripts.count == 2)
        #expect(scripts.allSatisfy { $0.injectionTime == .atDocumentStart })
        #expect(scripts[0].source.contains("body { color: red; }"))
        #expect(!scripts[0].source.contains("document.title"))
        #expect(scripts[1].source.contains("document.title = 'x';"))
        #expect(!scripts[1].source.contains("body { color: red; }"))
    }

    @Test("CSS-only overrides produce no JS script")
    @MainActor
    func cssOnlyIsOneScript() {
        let scripts = SiteOverrideInjector.makeUserScripts(
            overrides: [SiteOverride(pattern: "example.com", hiddenSelectors: [".ad"])]
        )
        #expect(scripts.count == 1)
        #expect(scripts[0].source.contains(".ad { display: none !important; }"))
    }

    @Test("The CSS script carries the host match and the style id")
    func cssContents() {
        let source = SiteOverrideInjector.cssSource(
            overrides: [
                SiteOverride(
                    pattern: "example.com",
                    css: "body { max-width: 70ch; }",
                    hiddenSelectors: [".rail"]
                )
            ]
        )
        #expect(source.contains("example.com"))
        #expect(source.contains("chord-site-override"))
        #expect(source.contains(".rail { display: none !important; }"))
        #expect(source.contains("body { max-width: 70ch; }"))
        // Suffix matching must require the dot, like the Swift matcher.
        #expect(source.contains("'.' + pattern"))
    }

    @Test("User JS is guarded by its host and wrapped so a throw cannot break the page")
    func jsContents() {
        let source = SiteOverrideInjector.jsSource(
            for: SiteOverride(pattern: "example.com", js: "document.title = 'overridden';")
        )
        #expect(source.contains("document.title = 'overridden';"))
        #expect(source.contains("'.' + pattern"))
        #expect(source.contains("catch (error)"))
    }

    @Test("The picker posts a selector and a host, and recognises a cancel")
    func pickerMessages() {
        #expect(
            SiteOverridePicker.result(from: ["selector": "#promo", "host": "example.com"])?
                .selector == "#promo"
        )
        #expect(SiteOverridePicker.result(from: ["cancel": true])?.cancelled == true)
        #expect(SiteOverridePicker.result(from: "nope") == nil)
        // The overlay must build an id-first selector, not a bare nth-of-type path.
        #expect(SiteOverridePicker.source.contains("querySelectorAll(byId)"))
        #expect(SiteOverridePicker.source.contains("data-testid"))
        #expect(SiteOverridePicker.source.contains("Escape"))
    }

    @Test("A host with a quote is escaped, not allowed to break the script")
    func hostIsEscaped() {
        let source = SiteOverrideInjector.jsSource(
            for: SiteOverride(pattern: "example.com", js: "1;")
        )
        #expect(source.contains("var pattern = \"example.com\""))
        #expect(!source.contains("var pattern = example.com"))
    }
}
