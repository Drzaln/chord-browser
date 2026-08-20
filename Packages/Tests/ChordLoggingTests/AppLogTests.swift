import Foundation
import Testing

@testable import ChordLogging

@Suite("File-backed logging", .serialized)
struct AppLogTests {

    private func tempLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "browser-log-tests-\(UUID().uuidString)")
            .appending(path: "chord.log")
    }

    @Test("Category handles are value-equal and share the sink")
    func categoriesAreValueEqual() {
        #expect(AppLog.category("store") == AppLog.category("store"))
        #expect(AppLog.category("store") != AppLog.category("engine"))
    }

    @Test("The mirror is off until installed")
    func mirrorIsOffUntilInstalled() {
        AppLog.install(fileURL: nil)
        defer { AppLog.install(fileURL: nil) }

        #expect(AppLog.fileURL == nil)
        AppLog.category("test").error("this must not create a file")
        FileSink.shared.flushForTesting()
        #expect(AppLog.fileURL == nil)
    }

    @Test("Writes the formatted line to the installed file")
    func writesToFile() throws {
        let url = tempLogURL()
        AppLog.install(fileURL: url, capBytes: 1_000_000)
        defer {
            AppLog.install(fileURL: nil)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        AppLog.category("test").notice("hello world")
        FileSink.shared.flushForTesting()

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("hello world"))
        #expect(text.contains("[test] notice:"))
    }

    @Test("Rotates the file when it passes the cap")
    func rotatesAtCap() throws {
        let url = tempLogURL()
        AppLog.install(fileURL: url, capBytes: 100)
        defer {
            AppLog.install(fileURL: nil)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        for i in 0..<40 {
            AppLog.category("test").debug("entry number \(i)")
        }
        FileSink.shared.flushForTesting()

        let backup = url.appendingPathExtension("1")
        #expect(
            FileManager.default.fileExists(atPath: backup.path),
            "expected a rotated backup file"
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
