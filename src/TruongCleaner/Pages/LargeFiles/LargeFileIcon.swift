import AppKit
import SwiftUI

/// Finder icon for a file, cached by path so scrolling a long table does not ask macOS again.
@MainActor
private enum LargeFileIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(forPath path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

/// A 16 pt file icon for table rows.
struct LargeFileIcon: View {
    let path: String

    var body: some View {
        Image(nsImage: LargeFileIconCache.icon(forPath: path))
            .resizable()
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}
