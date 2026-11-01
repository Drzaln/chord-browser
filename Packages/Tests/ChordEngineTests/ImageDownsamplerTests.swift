import AppKit
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ChordEngine

/// c1k.12: favicons and thumbnails are scaled and encoded on the CPU, from
/// any thread, at the size asked for.
struct ImageDownsamplerTests {
    private func image(width: Int, height: Int, red: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func encode(_ images: [CGImage], as type: UTType) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)!
        for image in images { CGImageDestinationAddImage(destination, image, nil) }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixelSize(of png: Data?) -> CGSize? {
        guard let png, let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    @Test func aPNGComesOutAtTheAskedSize() {
        let input = encode([image(width: 180, height: 120, red: 1)], as: .png)
        let output = ImageDownsampler.png(from: input, pixelSize: CGSize(width: 32, height: 32))
        #expect(pixelSize(of: output) == CGSize(width: 32, height: 32))
    }

    @Test func anIconsLargestFrameIsTheOneUsed() throws {
        let small = image(width: 16, height: 16, red: 0)
        let large = image(width: 64, height: 64, red: 1)
        let ico = encode([small, large], as: .ico)
        let output = try #require(ImageDownsampler.png(from: ico, pixelSize: CGSize(width: 32, height: 32)))
        let rep = try #require(NSBitmapImageRep(data: output))
        // The large frame is red; the small one has none.
        #expect((rep.colorAt(x: 16, y: 16)?.redComponent ?? 0) > 0.9)
    }

    @Test func anSVGIsRasterizedToo() {
        let svg = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="#c00"/></svg>
            """.utf8)
        let output = ImageDownsampler.png(from: svg, pixelSize: CGSize(width: 32, height: 32))
        #expect(pixelSize(of: output) == CGSize(width: 32, height: 32))
    }

    @Test func notAnImageIsNil() {
        #expect(ImageDownsampler.png(from: Data("hello".utf8), pixelSize: CGSize(width: 32, height: 32)) == nil)
    }

    @Test func itRunsOffTheMainThread() async {
        let input = encode([image(width: 256, height: 256, red: 1)], as: .png)
        let sizes = await withTaskGroup(of: CGSize?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    pixelSize(of: FaviconLoader.downsample(input))
                }
            }
            return await group.reduce(into: [CGSize?]()) { $0.append($1) }
        }
        #expect(sizes.allSatisfy { $0 == FaviconLoader.displaySize })
    }
}
