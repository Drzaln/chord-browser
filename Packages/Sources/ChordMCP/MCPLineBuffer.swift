import Foundation

/// Splits a byte stream into newline-delimited messages and holds the cap on
/// how long one may be.
///
/// The cap is checked on every `append`, so a client that never sends a newline
/// is caught one chunk past the limit — not after everything it had queued on
/// the socket has been read into memory.
struct MCPLineBuffer {
    let maxLineBytes: Int
    /// The unfinished line. Always zero-based, and it never holds a newline.
    private var pending = Data()

    init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    /// Adds `bytes` and returns the lines they completed, in order, without
    /// their newline. Blank lines are dropped. Returns nil when a line, finished
    /// or not, is longer than `maxLineBytes`: the stream is then abandoned.
    mutating func append<Bytes: Sequence>(_ bytes: Bytes) -> [Data]? where Bytes.Element == UInt8 {
        // What was pending has no newline, so the search starts at the new bytes.
        var searchFrom = pending.endIndex
        pending.append(contentsOf: bytes)

        var lines: [Data] = []
        var lineStart = pending.startIndex
        while let newline = pending[searchFrom...].firstIndex(of: 0x0A) {
            let line = pending[lineStart..<newline]
            guard line.count <= maxLineBytes else { return nil }
            if line.contains(where: { $0 != 0x20 && $0 != 0x0D }) { lines.append(Data(line)) }
            lineStart = pending.index(after: newline)
            searchFrom = lineStart
        }
        // One copy per append, however many lines it held.
        if lineStart != pending.startIndex { pending = Data(pending[lineStart...]) }
        guard pending.count <= maxLineBytes else { return nil }
        return lines
    }
}
