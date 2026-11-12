import Foundation
import Testing

@testable import ChordUI

/// The contract behind "find a setting": the pane row enums are the visible
/// rows, `SettingsCatalog` is the searchable description of exactly those rows,
/// and the ranking is fixed. The panes draw `Row.allCases` through
/// `SettingsRows`, so a row cannot appear on screen without going through the
/// enum; these tests fail if that enum and the catalog drift apart either way.
@Suite("Settings catalog")
struct SettingsCatalogTests {

    // MARK: - One catalog, one visible row list

    @Test("Every pane row has exactly one catalog entry")
    func catalogCoversEveryPaneRow() {
        assertCovers(GeneralRow.self, section: .general)
        assertCovers(SitesRow.self, section: .sites)
        assertCovers(PasswordsRow.self, section: .passwords)
        assertCovers(PrivacyRow.self, section: .privacy)
        assertCovers(ExtensionsRow.self, section: .extensions)
        assertCovers(BookmarksRow.self, section: .bookmarks)
        assertCovers(AgentsRow.self, section: .agents)
        assertCovers(UpdatesRow.self, section: .updates)
    }

    private func assertCovers<Row: SettingsRowType>(
        _ type: Row.Type, section: SettingsSection
    ) {
        let entries = SettingsCatalog.rows(in: section)
        #expect(entries.count == Row.allCases.count, "\(section.title) count")
        #expect(
            entries.map(\.id) == Row.allCases.map(\.rawValue),
            "\(section.title) order"
        )
        #expect(entries.allSatisfy { $0.section == section })
        #expect(Set(Row.allCases.map(\.rawValue)).count == Row.allCases.count)
    }

    @Test("Every section has rows, and the catalog order follows the picker")
    func sectionsCoveredInOrder() {
        #expect(
            SettingsCatalog.rows == SettingsSection.allCases.flatMap {
                SettingsCatalog.rows(in: $0)
            }
        )
        for section in SettingsSection.allCases {
            #expect(!SettingsCatalog.rows(in: section).isEmpty, "\(section.title)")
        }
    }

    @Test("Every entry is complete and finds itself by its own title")
    func everyEntryIsCompleteAndSelfFinding() {
        for row in SettingsCatalog.rows {
            #expect(!row.title.isEmpty)
            #expect(!row.blurb.isEmpty)
            #expect(!row.keywords.isEmpty)
            #expect(
                SettingsCatalog.search(row.title).contains { $0.id == row.id },
                "\(row.title) should find itself"
            )
        }
        for note in SettingsCatalog.notes {
            #expect(!note.title.isEmpty)
            #expect(!note.blurb.isEmpty)
            #expect(!note.keywords.isEmpty)
            #expect(SettingsCatalog.search(note.title).contains { $0.id == note.id })
        }
    }

    @Test("Every keyword finds its own entry")
    func everyKeywordFindsItsEntry() {
        for row in SettingsCatalog.rows {
            for keyword in row.keywords {
                #expect(
                    SettingsCatalog.search(keyword).contains { $0.id == row.id },
                    "\(row.title): \(keyword)"
                )
            }
        }
        for note in SettingsCatalog.notes {
            for keyword in note.keywords {
                #expect(
                    SettingsCatalog.search(keyword).contains { $0.id == note.id },
                    "\(note.title): \(keyword)"
                )
            }
        }
    }

    @Test("Row and note ids are unique")
    func idsAreUnique() {
        let ids = SettingsCatalog.rows.map(\.id) + SettingsCatalog.notes.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(SettingsCatalog.notes.allSatisfy { note in
            !SettingsCatalog.rows.contains { $0.id == note.id }
        })
    }

    // MARK: - What people actually type

    @Test(
        "Required words reach the right row first",
        arguments: [
            ("dark", "note.appearance"),
            ("appearance", "note.appearance"),
            ("adblock", "note.content-blocking"),
            ("blocking", "note.content-blocking"),
            ("suspend", "general.background-tabs"),
            ("hibernate", "general.archive-inactive-tabs"),
            ("default browser", "general.default-browser"),
            ("mcp", "agents.local-agents"),
            ("eval", "agents.javascript"),
            ("bookmark", "bookmarks.list"),
            ("routing", "sites.routing-rules"),
            ("css", "sites.site-overrides"),
            ("extension", "extensions.list"),
            ("update", "updates.check"),
            ("password", "passwords.saved-passwords"),
            ("space", "agents.shared-spaces"),
            ("zoom", "note.page-zoom"),
            ("import", "note.import"),
            ("download", "note.downloads"),
            ("notification", "privacy.site-permissions"),
            ("location", "privacy.site-permissions"),
            ("camera", "privacy.site-permissions"),
            ("mic", "privacy.site-permissions"),
            ("user agent", "general.user-agent"),
            ("private", "note.private-windows"),
            ("privacy", "privacy.clear-browsing-data"),
            ("search", "general.search-engine"),
            ("touch id", "passwords.vault-lock"),
            ("web store", "extensions.list"),
            ("chrome store", "extensions.list"),
        ]
    )
    func requiredWordsFindTheRightRow(query: String, expected: String) {
        let hits = SettingsCatalog.search(query)
        #expect(!hits.isEmpty, "\(query) found nothing")
        #expect(hits.first?.id == expected, "\(query) → \(hits.map(\.id))")
    }

    @Test("There is no proxy setting, so proxy finds nothing")
    func proxyIsNotInvented() {
        #expect(SettingsCatalog.search("proxy").isEmpty)
    }

    @Test("Search is case- and diacritic-insensitive")
    func caseAndDiacritics() {
        #expect(SettingsCatalog.normalized("CAFÉ") == "cafe")
        #expect(
            SettingsCatalog.search("PASSWORD").map(\.id)
                == SettingsCatalog.search("password").map(\.id)
        )
        #expect(SettingsCatalog.search("PÁSSWORD").first?.id == "passwords.saved-passwords")
    }

    @Test("Empty and unknown queries return nothing")
    func emptyAndUnknown() {
        #expect(SettingsCatalog.search("").isEmpty)
        #expect(SettingsCatalog.search("   ").isEmpty)
        #expect(SettingsCatalog.search("no-such-setting-zzz").isEmpty)
    }

    // MARK: - Ranking

    @Test("Title prefix beats title contains beats keyword")
    func rankingOrder() {
        let titlePrefix = SettingsCatalog.match(
            "read", title: "Reader", keywords: ["article"], blurb: "", section: "Sites"
        )
        let titleContains = SettingsCatalog.match(
            "eader", title: "Reader", keywords: ["article"], blurb: "", section: "Sites"
        )
        let keywordPrefix = SettingsCatalog.match(
            "artic", title: "Reader", keywords: ["article"], blurb: "", section: "Sites"
        )
        let keywordContains = SettingsCatalog.match(
            "ticle", title: "Reader", keywords: ["article"], blurb: "", section: "Sites"
        )
        let blurbContains = SettingsCatalog.match(
            "magazine", title: "Reader", keywords: [], blurb: "A magazine page", section: "Sites"
        )
        let sectionContains = SettingsCatalog.match(
            "sites", title: "Reader", keywords: [], blurb: "", section: "Sites"
        )

        #expect(titlePrefix?.score == 0)
        #expect(titleContains?.score == 1)
        #expect(keywordPrefix?.score == 2)
        #expect(keywordContains?.score == 3)
        #expect(blurbContains?.score == 4)
        #expect(sectionContains?.score == 5)
        #expect(
            SettingsCatalog.match(
                "zzz", title: "Reader", keywords: ["article"], blurb: "", section: "Sites"
            ) == nil
        )
        #expect(keywordPrefix?.keyword == "article")
    }

    @Test("A title match outranks a row that only carries the word as a keyword")
    func titleOutranksKeyword() {
        // "Archive Inactive Tabs" has the title; no other entry should beat it.
        let hits = SettingsCatalog.search("archive")
        #expect(hits.first?.id == "general.archive-inactive-tabs")
        #expect(hits.first?.score == 0)
    }

    @Test("All words must match, even across fields")
    func allWordsMustMatch() {
        #expect(SettingsCatalog.search("chrome web store").first?.id == "extensions.list")
        #expect(SettingsCatalog.search("site camera").first?.id == "privacy.site-permissions")
        #expect(SettingsCatalog.search("chrome camera").isEmpty)
    }
}
