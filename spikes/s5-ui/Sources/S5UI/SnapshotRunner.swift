import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `--snapshot <dir>`: render each page with `ImageRenderer` into PNGs, then quit.
///
/// RESULT OF THE S5 ATTEMPT: NOT USABLE. On macOS 27.0.1 / Xcode 27.0, `ImageRenderer`
/// returns a blank canvas for the grouped `Form` pages (List-backed, AppKit-hosted), and
/// the glass clean bar renders as a solid blue pill. Take real window screenshots instead.
/// Kept only so the report can point at it; the orchestrator may delete this file.
@MainActor
enum SnapshotRunner {
    static func runIfRequested() async {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot"), flag + 1 < args.count else { return }
        let directory = URL(filePath: args[flag + 1], directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("cannot create \(directory.path()): \(error)")
            exit(1)
        }

        let pages: [(name: String, view: AnyView)] = [
            ("overview", AnyView(OverviewPage())),
            ("smartclean", AnyView(SmartCleanPage())),
            ("systemdata", AnyView(SystemDataPage())),
        ]
        let schemes: [(name: String, scheme: ColorScheme)] = [("light", .light), ("dark", .dark)]

        var failures = 0
        for scheme in schemes {
            for page in pages {
                let content = page.view
                    .frame(width: 720, height: 820)
                    .background(.background)
                    .environment(\.colorScheme, scheme.scheme)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let file = directory.appending(path: "\(page.name)-\(scheme.name).png")
                if let image = renderer.cgImage, write(image, to: file) {
                    log("wrote \(file.path())")
                } else {
                    log("FAILED \(file.lastPathComponent)")
                    failures += 1
                }
            }
        }
        exit(failures == 0 ? 0 : 2)
    }

    private static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
