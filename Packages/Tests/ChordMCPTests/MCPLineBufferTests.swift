import Foundation
import Testing

@testable import ChordMCP

@Suite("MCP line buffer")
struct MCPLineBufferTests {
    private func strings(_ lines: [Data]?) -> [String]? {
        lines?.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("Lines come out whole, in order, however the bytes were chunked")
    func framing() {
        var buffer = MCPLineBuffer(maxLineBytes: 64)
        #expect(strings(buffer.append(Data("one\ntw".utf8))) == ["one"])
        #expect(strings(buffer.append(Data("o".utf8))) == [])
        #expect(strings(buffer.append(Data("\nthree\nfour\n".utf8))) == ["two", "three", "four"])
    }

    @Test("Blank lines are dropped")
    func blankLines() {
        var buffer = MCPLineBuffer(maxLineBytes: 64)
        #expect(strings(buffer.append(Data("\n \r\na\r\n\n".utf8))) == ["a\r"])
    }

    @Test("A line with no newline is refused one chunk past the cap, not after the whole stream")
    func unfinishedLineOverTheCap() {
        var buffer = MCPLineBuffer(maxLineBytes: 100)
        let chunk = Data(repeating: 0x61, count: 40)
        #expect(buffer.append(chunk) != nil)
        #expect(buffer.append(chunk) != nil)
        #expect(buffer.append(chunk) == nil)
    }

    @Test("A finished line over the cap is refused too")
    func finishedLineOverTheCap() {
        var buffer = MCPLineBuffer(maxLineBytes: 10)
        #expect(buffer.append(Data("0123456789\n".utf8)) != nil)
        #expect(buffer.append(Data("0123456789a\n".utf8)) == nil)
    }

    @Test("Many short lines may total far more than the cap")
    func manyShortLines() {
        var buffer = MCPLineBuffer(maxLineBytes: 16)
        let burst = Data(String(repeating: "abcdefgh\n", count: 1000).utf8)
        #expect(buffer.append(burst)?.count == 1000)
        #expect(strings(buffer.append(Data("tail\n".utf8))) == ["tail"])
    }
}
