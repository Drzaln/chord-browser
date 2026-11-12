import Foundation

/// Which byte encoding a bookmark file was decoded with. Netscape-format
/// exports are almost always UTF-8, but older browsers wrote Latin-1 (and
/// Windows-1252 files that are close enough to it for bookmark titles).
public enum BookmarkSourceEncoding: String, Sendable, Equatable, CaseIterable {
    case utf8
    case latin1
}

/// Why one candidate bookmark was left out of a plan.
public enum BookmarkImportSkipReason: String, Sendable, Equatable, CaseIterable {
    case unsupportedScheme
    case invalidURL
    case missingURL
    case duplicateInFolder
    case folderTooDeep
    case malformedLine

    public var label: String {
        switch self {
        case .unsupportedScheme: "unsupported URL scheme"
        case .invalidURL: "invalid URL"
        case .missingURL: "missing HREF"
        case .duplicateInFolder: "duplicate URL in folder"
        case .folderTooDeep: "folder deeper than the import limit"
        case .malformedLine: "malformed markup"
        }
    }
}

/// One thing the parser deliberately did not import. `detail` is the URL, the
/// folder path, or the offending markup, for the dry-run report; it is capped so
/// a single `data:` URL cannot inflate the plan.
public struct BookmarkImportSkip: Sendable, Equatable {
    public let line: Int
    public let reason: BookmarkImportSkipReason
    public let detail: String

    public init(line: Int, reason: BookmarkImportSkipReason, detail: String) {
        self.line = line
        self.reason = reason
        self.detail = String(detail.prefix(200))
    }
}

/// A folder found in the export, identified by its full path.
///
/// Chord's sidebar folders are flat, so an imported nested path becomes one
/// folder whose name is the path joined with " / " — `displayName`. This keeps
/// the depth information visible without inventing a second folder store.
public struct BookmarkImportFolder: Sendable, Equatable, Hashable {
    public let path: [String]

    public init(path: [String]) {
        self.path = path
    }

    /// The leaf name, as written in the export.
    public var name: String { path.last ?? "" }

    /// The flat Chord folder name for this path.
    public var displayName: String { path.joined(separator: " / ") }

    public var depth: Int { path.count }
}

/// One bookmark that a plan will write.
public struct BookmarkImportEntry: Sendable, Equatable {
    public let url: URL
    /// The folder this entry belongs to; empty means the top level (Chord's
    /// Pinned section, which is where root-level bookmarks land).
    public let folderPath: [String]
    /// The export's title, already entity-decoded and whitespace-normalised.
    /// Empty when the export had no title and no `<DD>` fallback.
    public var title: String

    public init(title: String, url: URL, folderPath: [String]) {
        self.title = title
        self.url = url
        self.folderPath = folderPath
    }

    public var folderName: String { folderPath.joined(separator: " / ") }
}

/// A parsed bookmark file, ready for a dry-run and then for an apply pass.
///
/// `entries` are the bookmarks that *will* be written; `skipped` are the ones
/// that will not, with the reason and source line. `folders` includes empty
/// folders, so an import reproduces the export's structure rather than only the
/// folders that happen to hold a bookmark.
public struct BookmarkImportPlan: Sendable, Equatable {
    public let folders: [BookmarkImportFolder]
    public let entries: [BookmarkImportEntry]
    public let skipped: [BookmarkImportSkip]
    /// Another folder nested past `NetscapeBookmarkParser.maximumFolderDepth`
    /// was dropped, along with its bookmarks.
    public let depthLimitReached: Bool
    public let encoding: BookmarkSourceEncoding

    public init(
        folders: [BookmarkImportFolder],
        entries: [BookmarkImportEntry],
        skipped: [BookmarkImportSkip] = [],
        depthLimitReached: Bool = false,
        encoding: BookmarkSourceEncoding = .utf8
    ) {
        self.folders = folders
        self.entries = entries
        self.skipped = skipped
        self.depthLimitReached = depthLimitReached
        self.encoding = encoding
    }

    public var folderCount: Int { folders.count }
    public var entryCount: Int { entries.count }
    public var skippedCount: Int { skipped.count }

    public func skippedCount(for reason: BookmarkImportSkipReason) -> Int {
        skipped.reduce(0) { $1.reason == reason ? $0 + 1 : $0 }
    }

    public var isEmpty: Bool { entries.isEmpty && folders.isEmpty && skipped.isEmpty }
}

/// Parses Netscape bookmark files — the `<!DOCTYPE NETSCAPE-Bookmark-file-1>`
/// format every browser exports.
///
/// The parser is deliberately forgiving: it never throws, skips malformed
/// markup, only keeps `http`/`https` URLs, and collapses an identical URL in
/// the same folder to one entry. It is pure and performs no I/O.
public enum NetscapeBookmarkParser {
    /// Folder nesting past this many levels is dropped and reported in the plan.
    public static let maximumFolderDepth = 64

    /// UTF-8 when the bytes are valid UTF-8, otherwise Latin-1.
    public static func decode(
        _ data: Data
    ) -> (text: String, encoding: BookmarkSourceEncoding) {
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8)
        }
        return (String(data: data, encoding: .isoLatin1) ?? "", .latin1)
    }

    public static func parse(_ data: Data) -> BookmarkImportPlan {
        let decoded = decode(data)
        return parse(html: decoded.text, encoding: decoded.encoding)
    }

    public static func parse(
        html: String, encoding: BookmarkSourceEncoding = .utf8
    ) -> BookmarkImportPlan {
        var text = html
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // Normalise CRLF/CR so reported line numbers match an editor's.
        text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var state = ParserState()
        for (offset, line) in text.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated() {
            state.process(line: String(line), lineNumber: offset + 1)
        }
        state.finish()
        return state.plan(encoding: encoding)
    }
}

// MARK: - Parser internals

private struct ParserState {
    private struct Frame {
        let path: [String]
        let overDepth: Bool
    }

    private struct PendingEntry {
        let line: Int
        let href: String?
    }

    private struct EntryKey: Hashable {
        let folder: [String]
        let url: String
    }

    private enum Capture {
        case entryTitle
        case folderName
        case description
    }

    private enum TagResult {
        case tag(Tag, next: Int)
        case malformed
        case notATag
    }

    private struct Tag {
        let name: String
        let isClosing: Bool
        let attributes: [String: String]
    }

    private var folderStack: [Frame] = []
    private var currentPath: [String] = []
    private var overDepth = false

    private var folders: [BookmarkImportFolder] = []
    private var seenFolders: Set<[String]> = []
    private var entries: [BookmarkImportEntry] = []
    private var seenEntries: Set<EntryKey> = []
    private var skipped: [BookmarkImportSkip] = []
    private var depthLimitReached = false

    private var inComment = false
    private var pendingFolderName: String?
    private var pendingEntry: PendingEntry?
    private var capture: Capture?
    private var captureText = ""
    /// Index of the most recently added entry, so a following `<DD>` can fill
    /// in a title the `<A>` element left empty.
    private var lastEntryIndex: Int?

    // MARK: Lines and tags

    mutating func process(line: String, lineNumber: Int) {
        if inComment {
            guard let end = line.range(of: "-->") else { return }
            inComment = false
            process(fragment: String(line[end.upperBound...]), lineNumber: lineNumber)
        } else {
            process(fragment: line, lineNumber: lineNumber)
        }
    }

    mutating func finish() {
        settleCapture()
        finalizePendingEntry()
        capture = nil
    }

    func plan(encoding: BookmarkSourceEncoding) -> BookmarkImportPlan {
        BookmarkImportPlan(
            folders: folders,
            entries: entries,
            skipped: skipped,
            depthLimitReached: depthLimitReached,
            encoding: encoding
        )
    }

    private mutating func process(fragment: String, lineNumber: Int) {
        let characters = Array(fragment)
        var index = 0
        var text = ""

        while index < characters.count {
            guard characters[index] == "<" else {
                text.append(characters[index])
                index += 1
                continue
            }

            append(text)
            text = ""

            if starts(with: "<!--", at: index, in: characters) {
                if let end = find("-->", from: index + 4, in: characters) {
                    index = end
                } else {
                    inComment = true
                    return
                }
                continue
            }

            if index + 1 < characters.count,
               characters[index + 1] == "!" || characters[index + 1] == "?" {
                guard let end = find(">", from: index, in: characters) else { return }
                index = end
                continue
            }

            switch parseTag(characters, from: index) {
            case .tag(let tag, let next):
                handle(tag, lineNumber: lineNumber)
                index = next
            case .malformed:
                noteMalformed(String(characters[index...]), lineNumber: lineNumber)
                return
            case .notATag:
                text.append("<")
                index += 1
            }
        }

        append(text)
        // A capture can span lines; keep the words apart.
        if capture != nil { captureText.append(" ") }
    }

    private func starts(with needle: String, at index: Int, in characters: [Character]) -> Bool {
        let pattern = Array(needle)
        guard index + pattern.count <= characters.count else { return false }
        for offset in pattern.indices where characters[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    private func find(_ needle: String, from start: Int, in characters: [Character]) -> Int? {
        guard !needle.isEmpty else { return start }
        let pattern = Array(needle)
        guard characters.count >= pattern.count else { return nil }
        var index = start
        while index + pattern.count <= characters.count {
            if characters[index] == pattern[0] {
                var matches = true
                for offset in 1..<pattern.count {
                    if characters[index + offset] != pattern[offset] {
                        matches = false
                        break
                    }
                }
                if matches { return index + pattern.count }
            }
            index += 1
        }
        return nil
    }

    private func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
            || character == "-" || character == ":" || character == "_"
    }

    /// Parses one tag at `start`, respecting quoted attribute values so a `>`
    /// inside `HREF="…"` does not end the tag. Anything unterminated is
    /// `malformed`; the caller skips the rest of the line rather than throwing.
    private func parseTag(_ characters: [Character], from start: Int) -> TagResult {
        var index = start + 1
        guard index < characters.count else { return .notATag }

        var isClosing = false
        if characters[index] == "/" {
            isClosing = true
            index += 1
        }

        let nameStart = index
        while index < characters.count, isNameCharacter(characters[index]) { index += 1 }
        guard index > nameStart else { return .notATag }
        let name = String(characters[nameStart..<index]).lowercased()

        if isClosing {
            while index < characters.count, characters[index] != ">" { index += 1 }
            guard index < characters.count else { return .malformed }
            return .tag(Tag(name: name, isClosing: true, attributes: [:]), next: index + 1)
        }

        var attributes: [String: String] = [:]
        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { return .malformed }

            if characters[index] == ">" {
                return .tag(
                    Tag(name: name, isClosing: false, attributes: attributes),
                    next: index + 1
                )
            }
            if characters[index] == "/" {
                index += 1
                continue
            }

            let attributeStart = index
            while index < characters.count,
                  !characters[index].isWhitespace,
                  characters[index] != "=",
                  characters[index] != ">",
                  characters[index] != "/" {
                index += 1
            }
            guard index > attributeStart else {
                // A stray character in attribute position; move past it so a
                // broken tag cannot spin forever.
                index += 1
                continue
            }
            let attribute = String(characters[attributeStart..<index]).lowercased()

            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count, characters[index] == "=" else {
                if attributes[attribute] == nil { attributes[attribute] = "" }
                continue
            }

            index += 1
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { return .malformed }

            let value: String
            if characters[index] == "\"" || characters[index] == "'" {
                let quote = characters[index]
                index += 1
                let valueStart = index
                while index < characters.count, characters[index] != quote { index += 1 }
                guard index < characters.count else { return .malformed }
                value = decodeEntities(String(characters[valueStart..<index]))
                index += 1
            } else {
                let valueStart = index
                while index < characters.count,
                      !characters[index].isWhitespace,
                      characters[index] != ">" {
                    index += 1
                }
                value = decodeEntities(String(characters[valueStart..<index]))
            }
            if attributes[attribute] == nil { attributes[attribute] = value }
        }

        return .malformed
    }

    private mutating func noteMalformed(_ raw: String, lineNumber: Int) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let relevant = ["<a", "<h3", "<dl", "<dt", "<dd"]
        guard relevant.contains(where: lower.hasPrefix) else { return }
        skipped.append(
            BookmarkImportSkip(
                line: lineNumber,
                reason: .malformedLine,
                detail: String(trimmed.prefix(120))
            )
        )
    }

    // MARK: Structure events

    private mutating func handle(_ tag: Tag, lineNumber: Int) {
        switch tag.name {
        case "a":
            if tag.isClosing {
                finalizePendingEntry()
                capture = nil
            } else {
                settleCapture()
                finalizePendingEntry()
                pendingEntry = PendingEntry(
                    line: lineNumber, href: tag.attributes["href"]
                )
                capture = .entryTitle
                captureText = ""
            }
        case "h3":
            if tag.isClosing {
                let name = normalise(
                    decodeEntities(capture == .folderName ? captureText : "")
                )
                pendingFolderName = name.isEmpty ? "Untitled Folder" : name
                capture = nil
            } else {
                settleCapture()
                finalizePendingEntry()
                capture = .folderName
                captureText = ""
            }
        case "dd":
            if tag.isClosing {
                let description = normalise(
                    decodeEntities(capture == .description ? captureText : "")
                )
                applyDescription(description)
                capture = nil
            } else {
                settleCapture()
                finalizePendingEntry()
                capture = .description
                captureText = ""
            }
        case "dt":
            settleCapture()
            finalizePendingEntry()
        case "dl":
            if tag.isClosing {
                closeList()
            } else {
                openList()
            }
        default:
            // Tags inside a title (`<B>`, `<I>`, …) contribute their text only.
            break
        }
    }

    /// A `<DL>` opens a folder when the preceding `<H3>` named one, and a plain
    /// nesting level otherwise (the export's outermost list has no folder).
    private mutating func openList() {
        settleCapture()
        finalizePendingEntry()
        folderStack.append(Frame(path: currentPath, overDepth: overDepth))

        guard let name = pendingFolderName, !name.isEmpty else { return }
        pendingFolderName = nil

        guard currentPath.count < NetscapeBookmarkParser.maximumFolderDepth else {
            depthLimitReached = true
            overDepth = true
            return
        }

        currentPath.append(name)
        if seenFolders.insert(currentPath).inserted {
            folders.append(BookmarkImportFolder(path: currentPath))
        }
        overDepth = false
    }

    private mutating func closeList() {
        settleCapture()
        finalizePendingEntry()
        pendingFolderName = nil
        guard let frame = folderStack.popLast() else { return }
        currentPath = frame.path
        overDepth = frame.overDepth
    }

    /// Optional end tags (`</DD>`, and occasionally `</H3>`) are common in
    /// hand-written exports. When a new structural tag arrives with a capture
    /// still open, commit it before starting the next one.
    private mutating func settleCapture() {
        guard let capture else { return }
        switch capture {
        case .entryTitle:
            break // The pending entry consumes it when it is finalized.
        case .folderName:
            let name = normalise(decodeEntities(captureText))
            pendingFolderName = name.isEmpty ? "Untitled Folder" : name
            self.capture = nil
        case .description:
            applyDescription(normalise(decodeEntities(captureText)))
            self.capture = nil
        }
    }

    // MARK: Entries

    private mutating func append(_ text: String) {
        guard capture != nil, !text.isEmpty else { return }
        captureText.append(text)
    }

    private mutating func finalizePendingEntry() {
        guard let pending = pendingEntry else { return }
        pendingEntry = nil
        lastEntryIndex = nil

        let title = normalise(
            decodeEntities(capture == .entryTitle ? captureText : "")
        )
        capture = nil
        guard let href = pending.href?.trimmingCharacters(in: .whitespacesAndNewlines),
              !href.isEmpty else {
            skipped.append(
                BookmarkImportSkip(line: pending.line, reason: .missingURL, detail: "")
            )
            return
        }

        guard let url = acceptedURL(href, line: pending.line) else { return }

        guard !overDepth else {
            skipped.append(
                BookmarkImportSkip(
                    line: pending.line,
                    reason: .folderTooDeep,
                    detail: currentPath.joined(separator: " / ")
                )
            )
            return
        }

        let key = EntryKey(folder: currentPath, url: url.absoluteString)
        guard seenEntries.insert(key).inserted else {
            skipped.append(
                BookmarkImportSkip(
                    line: pending.line,
                    reason: .duplicateInFolder,
                    detail: url.absoluteString
                )
            )
            return
        }

        entries.append(
            BookmarkImportEntry(title: title, url: url, folderPath: currentPath)
        )
        lastEntryIndex = entries.count - 1
    }

    /// `<DD>` text after an untitled `<A>` becomes that entry's title.
    private mutating func applyDescription(_ description: String) {
        guard let index = lastEntryIndex, entries.indices.contains(index) else { return }
        guard entries[index].title.isEmpty, !description.isEmpty else {
            lastEntryIndex = nil
            return
        }
        entries[index].title = description
        lastEntryIndex = nil
    }

    private mutating func acceptedURL(_ raw: String, line: Int) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            skipped.append(
                BookmarkImportSkip(line: line, reason: .invalidURL, detail: raw)
            )
            return nil
        }
        guard scheme == "http" || scheme == "https" else {
            skipped.append(
                BookmarkImportSkip(
                    line: line,
                    reason: .unsupportedScheme,
                    detail: "\(scheme): \(raw)"
                )
            )
            return nil
        }
        guard let host = url.host(), !host.isEmpty else {
            skipped.append(
                BookmarkImportSkip(line: line, reason: .invalidURL, detail: raw)
            )
            return nil
        }
        return url
    }

    // MARK: Text

    private func normalise(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

// MARK: - Entities

private let namedEntities: [String: String] = [
    "amp": "&",
    "apos": "'",
    "gt": ">",
    "hellip": "…",
    "ldquo": "“",
    "lsquo": "‘",
    "lt": "<",
    "mdash": "—",
    "nbsp": "\u{00A0}",
    "ndash": "–",
    "quot": "\"",
    "rdquo": "”",
    "rsquo": "’",
]

private func decodeEntities(_ raw: String) -> String {
    guard raw.contains("&") else { return raw }

    var result = ""
    var index = raw.startIndex
    while index < raw.endIndex {
        guard raw[index] == "&" else {
            result.append(raw[index])
            index = raw.index(after: index)
            continue
        }

        let bodyStart = raw.index(after: index)
        let tail = raw[bodyStart...]
        guard let semicolon = tail.prefix(12).firstIndex(of: ";") else {
            result.append("&")
            index = bodyStart
            continue
        }

        let body = String(tail[..<semicolon])
        if let decoded = decodeEntity(body) {
            result += decoded
            index = raw.index(after: semicolon)
        } else {
            result.append("&")
            index = bodyStart
        }
    }
    return result
}

private func decodeEntity(_ body: String) -> String? {
    if body.hasPrefix("#") {
        let digits = body.dropFirst()
        let value: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }
    return namedEntities[body.lowercased()]
}
