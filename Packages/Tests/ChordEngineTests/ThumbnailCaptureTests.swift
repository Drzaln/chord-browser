import AppKit
import Foundation
import Testing

@testable import ChordEngine

/// The Ctrl+Tab switcher's thumbnail capture rejects blank images — WebKit
/// hands back an empty, transparent, or solid-colour snapshot for a pane that
/// is not on screen or has not painted, and storing that would show a white or
/// black card instead of the favicon-tile fallback.
@Suite("Thumbnail capture")
@MainActor
struct ThumbnailCaptureTests {

    private func makeRep(drawing: () -> Void) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 40,
            pixelsHigh: 30,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawing()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @Test("A solid-colour capture is treated as blank")
    func solidColourIsBlank() {
        let rep = makeRep {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 40, height: 30).fill()
        }

        #expect(rep != nil)
        #expect(WebKitEngine.hasVisibleContent(rep!) == false)
    }

    @Test("A transparent capture is treated as blank")
    func transparentIsBlank() {
        let rep = makeRep {
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: 40, height: 30).fill()
        }

        #expect(rep != nil)
        #expect(WebKitEngine.hasVisibleContent(rep!) == false)
    }

    @Test("A capture with actual content is kept")
    func contentIsKept() {
        let rep = makeRep {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 40, height: 30).fill()
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: 20, height: 30).fill()
        }

        #expect(rep != nil)
        #expect(WebKitEngine.hasVisibleContent(rep!) == true)
    }
}