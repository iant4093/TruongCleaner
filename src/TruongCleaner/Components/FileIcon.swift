import AppKit
import SwiftUI

/// Finder icons by path. `NSWorkspace.icon(forFile:)` is asked once per path.
@MainActor
enum FileIconCache {
    /// The cache is emptied when it grows past this many icons.
    static let limit = 512

    private static var images: [String: NSImage] = [:]

    /// The Finder icon for `path`.
    static func image(forPath path: String) -> NSImage {
        if let cached = images[path] { return cached }
        if images.count >= limit { images.removeAll(keepingCapacity: true) }
        let image = NSWorkspace.shared.icon(forFile: path)
        images[path] = image
        return image
    }
}

/// The Finder icon of a file or folder, drawn square at `size` points.
struct FileIcon: View {
    let url: URL
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: FileIconCache.image(forPath: url.path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
