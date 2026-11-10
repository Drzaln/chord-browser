import Foundation
import Testing

/// gn0.8: a button whose label is only an image is read by VoiceOver as the
/// symbol's own name ("trash"), which says nothing about what it removes.
/// This reads the ChordUI sources and fails on any such button that carries
/// no `accessibilityLabel`.
///
/// It is a text check, not a parser. It finds a `Button` by indentation: the
/// block runs to the next line at the same depth that is not a modifier or a
/// closing brace. A button built some other way needs its own look.
@Suite("Icon-only buttons are labelled")
struct IconButtonLabelTests {
    private static let sources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ChordUITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // Packages
        .appendingPathComponent("Sources/ChordUI", isDirectory: true)

    /// `file:line` of each icon-only button with no accessibility label.
    static func unlabelled(in text: String, file: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var found: [String] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.drop { $0 == " " }
            guard trimmed.hasPrefix("Button(") || trimmed.hasPrefix("Button {") else { continue }
            // `Button("Title")` and `Button(title, …)` carry their own text.
            if trimmed.hasPrefix("Button(\"") { continue }
            let depth = line.prefix { $0 == " " }.count
            var block = [line]
            var next = index + 1
            while next < lines.count, next < index + 60 {
                let candidate = lines[next]
                let body = candidate.drop { $0 == " " }
                if !body.isEmpty {
                    let candidateDepth = candidate.prefix { $0 == " " }.count
                    if candidateDepth < depth { break }
                    if candidateDepth == depth, !(body.hasPrefix(".") || body.hasPrefix("}") || body.hasPrefix(")")) {
                        break
                    }
                }
                block.append(candidate)
                next += 1
            }
            let joined = block.joined(separator: "\n")
            guard joined.contains("Image(") else { continue }
            if joined.contains("Text(") || joined.contains("Label(") { continue }
            if joined.contains("accessibilityLabel") { continue }
            found.append("\(file):\(index + 1)")
        }
        return found
    }

    @Test("The check sees an unlabelled icon button, and passes a labelled one")
    func checkWorks() {
        let bad = """
                Button(action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Remove")
                Text("after")
            """
        #expect(Self.unlabelled(in: bad, file: "x").count == 1)
        let good = bad.replacingOccurrences(
            of: ".help(\"Remove\")", with: ".help(\"Remove\")\n    .accessibilityLabel(\"Remove rule\")")
        #expect(Self.unlabelled(in: good, file: "x").isEmpty)
        let titled = """
                Button {
                    go()
                } label: {
                    Image(systemName: "arrow.right")
                    Text("Go")
                }
            """
        #expect(Self.unlabelled(in: titled, file: "x").isEmpty)
    }

    @Test("No icon-only button in ChordUI is without an accessibility label")
    func allLabelled() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var found: [String] = []
        var files = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            found += Self.unlabelled(in: text, file: url.lastPathComponent)
        }
        // Guards the path: a moved directory must not make this pass on nothing.
        #expect(files > 50)
        #expect(found.isEmpty, "add .accessibilityLabel to: \(found.joined(separator: ", "))")
    }
}
