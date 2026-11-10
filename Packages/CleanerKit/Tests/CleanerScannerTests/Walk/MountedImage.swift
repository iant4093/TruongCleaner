import CleanerTestSupport
import Foundation
import Testing

/// A small APFS disk image mounted on a folder of a fixture tree, so that a test has a real second
/// volume inside the tree. The image file lives in the fixture and so does the mount folder; nothing
/// outside `build/test-fixtures/` is touched. Detach it before the fixture is removed.
struct MountedImage {
    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// The folder the image is mounted on (inside the fixture tree).
    let mountPoint: URL
    private let log: URL

    /// Creates an image and mounts it on `relativeMountFolder`. Throws `Unavailable` when `hdiutil` fails,
    /// for example on a runner that does not allow disk images.
    static func attach(in tree: FixtureTree, at relativeMountFolder: String) async throws -> MountedImage {
        let image = tree.url(for: "scan-volume.sparseimage")
        let log = tree.url(for: "scan-volume.log")
        let mountPoint = try tree.addDirectory(relativeMountFolder)
        _ = try await hdiutil(
            ["create", "-size", "20m", "-type", "SPARSE", "-fs", "APFS", "-volname", "TCScan", image.path], log: log)
        _ = try await hdiutil(
            ["attach", "-nobrowse", "-noverify", "-noautofsck", "-mountpoint", mountPoint.path, image.path], log: log)
        return MountedImage(mountPoint: mountPoint, log: log)
    }

    /// Mounts an image, runs `body`, and detaches whether `body` returns or throws. When no image can be
    /// mounted here the test records a known issue and `body` does not run.
    static func with(
        _ tree: FixtureTree, at relativeMountFolder: String, _ body: (MountedImage) async throws -> Void
    ) async throws {
        let image: MountedImage
        do {
            image = try await attach(in: tree, at: relativeMountFolder)
        } catch {
            withKnownIssue("Could not attach a disk image here: \(error)") { throw error }
            return
        }
        do {
            try await body(image)
        } catch {
            await image.detach()
            throw error
        }
        await image.detach()
    }

    /// Unmounts the image. Retries, then forces, so a busy volume cannot leave a mount behind.
    func detach() async {
        for attempt in 0..<3 {
            if (try? await Self.hdiutil(["detach", mountPoint.path, attempt == 2 ? "-force" : "-quiet"], log: log)) != nil {
                return
            }
        }
    }

    /// Runs `hdiutil` without parking a thread: output goes to a file and the exit is awaited.
    /// A call still running after 90 s is terminated.
    private static func hdiutil(_ arguments: [String], log: URL) async throws -> Data {
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw Unavailable(description: "cannot create log")
        }
        let sink = try FileHandle(forWritingTo: log)
        defer { try? sink.close() }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = sink
        process.standardError = sink
        process.standardInput = FileHandle.nullDevice
        let watchdog = Task {
            try await Task.sleep(for: .seconds(90))
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let output = (try? Data(contentsOf: log)) ?? Data()
        guard status == 0 else {
            throw Unavailable(
                description: "hdiutil \(arguments.first ?? "") failed: \(String(decoding: output.prefix(200), as: UTF8.self))")
        }
        return output
    }
}
