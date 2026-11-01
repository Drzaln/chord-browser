import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Scales an image to a small fixed pixel size and encodes it as PNG, on the
/// CPU, from any thread (c1k.12).
///
/// Favicons were drawn with `NSImage.lockFocus` off the main thread and
/// encoded through `NSBitmapImageRep`. Both can land on QuartzCore's
/// accelerated CGContext, which needs a Metal context: after ~7 hours of
/// background video one could not be made, and QuartzCore aborts the app
/// (`CA::OGL::new_metal_context` assert) rather than fail the draw. A plain
/// bitmap context and ImageIO never touch the GPU.
enum ImageDownsampler {
    /// The largest frame in `data` (an .ico holds several), at `pixelSize`.
    /// Formats ImageIO cannot read (an SVG favicon) go through AppKit's
    /// rasterizer once, then the same CPU path.
    static func png(from data: Data, pixelSize: CGSize) -> Data? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            var best: CGImage?
            for index in 0..<CGImageSourceGetCount(source) {
                guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
                if frame.width > best?.width ?? 0 { best = frame }
            }
            if let best { return png(from: best, pixelSize: pixelSize) }
        }
        guard let image = NSImage(data: data) else { return nil }
        var rect = CGRect(origin: .zero, size: pixelSize)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            .flatMap { png(from: $0, pixelSize: pixelSize) }
    }

    static func png(from image: CGImage, pixelSize: CGSize) -> Data? {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
