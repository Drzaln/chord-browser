import AppKit
import Foundation
import SwiftUI

/// Decodes favicon bytes once and keeps the decoded image.
///
/// Row bodies must never decode an image — a sidebar that rebuilds `NSImage`
/// on every redraw is exactly the accidental CPU burn 6.4 warns about.
@MainActor
final class FaviconCache {
    static let shared = FaviconCache()

    private var images: [UUID: (hash: Int, image: Image)] = [:]

    func image(paneID: UUID, data: Data?) -> Image? {
        guard let data else {
            images[paneID] = nil
            return nil
        }

        let hash = data.hashValue
        if let cached = images[paneID], cached.hash == hash { return cached.image }

        guard let nsImage = NSImage(data: data) else { return nil }
        let image = Image(nsImage: nsImage)
        images[paneID] = (hash, image)
        return image
    }

    func forget(paneID: UUID) {
        images[paneID] = nil
    }
}
