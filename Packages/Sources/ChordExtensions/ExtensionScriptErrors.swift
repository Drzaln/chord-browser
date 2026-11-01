import Foundation

/// An uncaught exception or unhandled promise rejection in one of an
/// extension's scripts (9ba). WebKit reports these on the context since the
/// Safari 27 runtime; until then an extension that threw just stopped doing
/// things ("the popup spins forever"), with nothing to show why.
public struct ExtensionScriptError: Sendable, Equatable, Identifiable {
    public var id: String { message }
    /// WebKit's text: the error, and where it was thrown in the extension's
    /// own file ("Error: x (background.js:12:5)").
    public let message: String
    /// How many times it has been reported since the extension loaded.
    public let count: Int

    public init(message: String, count: Int) {
        self.message = message
        self.count = count
    }
}

/// Each loaded extension's script errors, by "space|slug". WebKit hands over
/// the whole list on every change, so this keeps the distinct messages with
/// a count and says which are new, to log each once rather than every time an
/// extension retries something that fails (Bitwarden's native messaging every
/// five seconds).
struct ExtensionScriptErrorLog {
    /// Distinct messages kept per extension; the oldest go first.
    static let limit = 20

    private var entries: [String: [ExtensionScriptError]] = [:]

    /// Takes the context's current error list and returns the messages not
    /// seen before for `key`.
    mutating func record(_ messages: [String], key: String) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for message in messages {
            if counts[message] == nil { order.append(message) }
            counts[message, default: 0] += 1
        }
        var kept = entries[key] ?? []
        var fresh: [String] = []
        for message in order {
            let seen = counts[message] ?? 1
            if let index = kept.firstIndex(where: { $0.message == message }) {
                kept[index] = ExtensionScriptError(
                    message: message, count: max(kept[index].count, seen)
                )
            } else {
                kept.append(ExtensionScriptError(message: message, count: seen))
                fresh.append(message)
            }
        }
        entries[key] = Array(kept.suffix(Self.limit))
        return fresh
    }

    func errors(for key: String) -> [ExtensionScriptError] {
        entries[key] ?? []
    }

    mutating func forget(_ key: String) {
        entries[key] = nil
    }

    /// WebKit counts lines in the worker file as loaded, which starts with
    /// Chord's shim (`ExtensionShims.prepare`); `offset` is the shim's length,
    /// so "(background.js:3386:9)" reads as the extension's own line 3.
    static func withShimRemoved(
        from message: String, workerFile: String?, offset: Int
    ) -> String {
        guard let workerFile, offset > 0 else { return message }
        let name = NSRegularExpression.escapedPattern(for: workerFile)
        guard let regex = try? NSRegularExpression(pattern: "\(name):(\\d+)(:\\d+)?\\)") else {
            return message
        }
        var result = message
        let range = NSRange(result.startIndex..., in: result)
        for match in regex.matches(in: result, range: range).reversed() {
            guard let lineRange = Range(match.range(at: 1), in: result),
                  let line = Int(result[lineRange]), line > offset
            else { continue }
            result.replaceSubrange(lineRange, with: String(line - offset))
        }
        return result
    }
}
