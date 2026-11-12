import ChordCore
import Foundation
import Testing

@Suite("Netscape bookmark import")
struct BookmarkImportTests {

    /// A realistic browser export: mixed attribute order, both quote styles,
    /// an unquoted HREF, entities, an untitled entry with a `<DD>` fallback, and
    /// every URL scheme Chord refuses to import.
    private let chromeStyleExport = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file. Do not edit. -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><A HREF="https://root.example/" ADD_DATE="1">Root</A>
            <DT><H3 ADD_DATE="1" LAST_MODIFIED="2" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Bar</H3>
            <DL><p>
                <DT><A HREF="https://bar.example/?a=1&amp;b=2" ADD_DATE="1">Bar &amp; Grill</A>
                <DT><A ADD_DATE="1" HREF='https://single.example/'>Single 'Quotes'</A>
                <DT><A HREF=https://unquoted.example/>Unquoted</A>
                <DT><H3>Research &amp; Dev</H3>
                <DL><p>
                    <DT><A HREF="https://dev.example/">Dev</A>
                    <DT><A HREF="https://dev.example/">Dev again</A>
                    <DT><A HREF="https://bar.example/?a=1&amp;b=2">Same URL, other folder</A>
                </DL><p>
                <DT><A HREF="javascript:alert(1)">Script</A>
                <DT><A HREF="data:text/html,hi">Data</A>
                <DT><A HREF="file:///tmp/x">File</A>
                <DT><A HREF="https://fallback.example/"></A>
                <DD>Fallback from DD
                <DT><A HREF="noscheme.example">No scheme</A>
                <DT><A HREF="HTTPS://UPPER.example/Path">Upper scheme</A>
            </DL><p>
            <DT><H3>Empty</H3>
            <DL><p>
            </DL><p>
        </DL><p>
        """

    @Test("A browser export keeps its folders, titles, and http(s) entries")
    func parsesRealisticExport() {
        let plan = NetscapeBookmarkParser.parse(html: chromeStyleExport)

        #expect(plan.encoding == .utf8)
        #expect(plan.folderCount == 3)
        #expect(
            plan.folders.map(\.displayName)
                == ["Bookmarks Bar", "Bookmarks Bar / Research & Dev", "Empty"]
        )
        #expect(plan.folders.map(\.depth) == [1, 2, 1])
        #expect(plan.entryCount == 8)

        #expect(
            plan.entries.map(\.title)
                == [
                    "Root",
                    "Bar & Grill",
                    "Single 'Quotes'",
                    "Unquoted",
                    "Dev",
                    "Same URL, other folder",
                    "Fallback from DD",
                    "Upper scheme",
                ]
        )
        #expect(plan.entries.map(\.url.absoluteString) == [
            "https://root.example/",
            "https://bar.example/?a=1&b=2",
            "https://single.example/",
            "https://unquoted.example/",
            "https://dev.example/",
            "https://bar.example/?a=1&b=2",
            "https://fallback.example/",
            "HTTPS://UPPER.example/Path",
        ])
        #expect(plan.entries.map(\.folderName) == [
            "", "Bookmarks Bar", "Bookmarks Bar", "Bookmarks Bar", "Bookmarks Bar / Research & Dev",
            "Bookmarks Bar / Research & Dev", "Bookmarks Bar", "Bookmarks Bar",
        ])
    }

    @Test("Only http(s) survives, and duplicates collapse per folder")
    func skipsUnsupportedAndDuplicates() {
        let plan = NetscapeBookmarkParser.parse(html: chromeStyleExport)

        #expect(plan.skippedCount(for: .unsupportedScheme) == 3)
        #expect(plan.skippedCount(for: .invalidURL) == 1)
        #expect(plan.skippedCount(for: .duplicateInFolder) == 1)
        #expect(plan.skippedCount == 5)
        #expect(!plan.depthLimitReached)
        #expect(plan.skipped.allSatisfy { $0.line > 0 })
    }

    @Test("Malformed lines are skipped without losing the good ones")
    func malformedLinesAreSkipped() {
        let html = """
            <DL><p>
            <DT><A HREF="https://before.example/">Before</A>
            <DT><A HREF="https://broken.example/" ADD_DATE="1"
            <DT><A HREF="https://after.example/">After</A>
            </DL><p>
            """
        let plan = NetscapeBookmarkParser.parse(html: html)

        #expect(plan.entries.map { $0.url.host() } == ["before.example", "after.example"])
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped.first?.reason == .malformedLine)
        #expect(plan.skipped.first?.line == 3)
    }

    @Test("An unclosed A still imports at end of file")
    func unclosedEntryIsRecovered() {
        let plan = NetscapeBookmarkParser.parse(
            html: "<DL><p><DT><A HREF=\"https://eof.example/\">End of file"
        )

        #expect(plan.entryCount == 1)
        #expect(plan.entries.first?.title == "End of file")
    }

    @Test("A DD without a closing tag still provides the title fallback")
    func unclosedDescriptionIsApplied() {
        let plan = NetscapeBookmarkParser.parse(
            html: """
                <DL><p>
                <DT><A HREF="https://fallback.example/"></A>
                <DD>Description without a closing tag
                <DT><A HREF="https://next.example/">Next</A>
                </DL><p>
                """
        )

        #expect(plan.entries.map(\.title) == ["Description without a closing tag", "Next"])
    }

    @Test("A DD never overrides an existing title")
    func descriptionDoesNotOverrideTitle() {
        let plan = NetscapeBookmarkParser.parse(
            html: """
                <DL><p>
                <DT><A HREF="https://titled.example/">The title</A>
                <DD>The description
                </DL><p>
                """
        )

        #expect(plan.entries.first?.title == "The title")
    }

    @Test("Folder nesting is capped at 64 levels and reported")
    func depthIsCapped() {
        var html = "<DL><p>\n"
        for depth in 1...70 {
            html += "<DT><H3>Level \(depth)</H3>\n<DL><p>\n"
            if depth == 64 {
                html += "<DT><A HREF=\"https://at-cap.example/\">At cap</A>\n"
            }
            if depth == 70 {
                html += "<DT><A HREF=\"https://too-deep.example/\">Too deep</A>\n"
            }
        }
        for _ in 1...70 { html += "</DL><p>\n" }
        html += "</DL><p>"

        let plan = NetscapeBookmarkParser.parse(html: html)

        #expect(plan.depthLimitReached)
        #expect(plan.folderCount == NetscapeBookmarkParser.maximumFolderDepth)
        #expect(plan.folders.last?.depth == NetscapeBookmarkParser.maximumFolderDepth)
        #expect(plan.entries.map { $0.url.host() } == ["at-cap.example"])
        #expect(plan.skippedCount(for: .folderTooDeep) == 1)
    }

    @Test("Latin-1 is the fallback when the bytes are not valid UTF-8")
    func latin1Fallback() {
        let prefix = "<DL><p><DT><A HREF=\"https://cafe.example/\">Caf"
        let suffix = "</A></DL><p>"
        var bytes = Array(prefix.utf8)
        bytes.append(0xE9)  // é in Latin-1
        bytes.append(contentsOf: Array(suffix.utf8))

        let plan = NetscapeBookmarkParser.parse(Data(bytes))

        #expect(plan.encoding == .latin1)
        #expect(plan.entries.first?.title == "Café")
    }

    @Test("Valid UTF-8 is preferred over the Latin-1 fallback")
    func utf8Wins() {
        let plan = NetscapeBookmarkParser.parse(
            Data("<DL><p><DT><A HREF=\"https://cafe.example/\">Café</A></DL><p>".utf8)
        )

        #expect(plan.encoding == .utf8)
        #expect(plan.entries.first?.title == "Café")
    }

    @Test("Attributes may arrive in any order and unquoted")
    func attributeOrderIsIrrelevant() {
        let plan = NetscapeBookmarkParser.parse(
            html: """
                <DL><p>
                <DT><A ADD_DATE=1 HREF=https://one.example/>One</A>
                <DT><A HREF = "https://two.example/" ICON="data:image/png;base64,AAAA">Two</A>
                </DL><p>
                """
        )

        #expect(plan.entries.map { $0.url.host() } == ["one.example", "two.example"])
        #expect(plan.entries.map(\.title) == ["One", "Two"])
    }

    @Test("An unterminated comment hides its contents but not the rest of the file")
    func unterminatedCommentRecovers() {
        let plan = NetscapeBookmarkParser.parse(
            html: """
                <DL><p>
                <!-- this comment never closes on this line
                <DT><A HREF="https://hidden.example/">Hidden</A>
                -->
                <DT><A HREF="https://visible.example/">Visible</A>
                </DL><p>
                """
        )

        #expect(plan.entries.map { $0.url.host() } == ["visible.example"])
    }

    @Test("An empty file produces an empty plan")
    func emptyFile() {
        let plan = NetscapeBookmarkParser.parse(html: "")

        #expect(plan.isEmpty)
        #expect(plan.entryCount == 0)
        #expect(plan.folderCount == 0)
        #expect(plan.skippedCount == 0)
    }
}

#if false
#endif
