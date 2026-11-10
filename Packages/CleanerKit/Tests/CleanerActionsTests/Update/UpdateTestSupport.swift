import CleanerTestSupport
import CryptoKit
import Darwin
import Foundation
import os
import Testing

@testable import CleanerActions

/// Failure of a helper tool that a test fixture needs.
struct ToolError: Error, CustomStringConvertible {
    let description: String
}

/// Runs a system tool to completion for fixture setup. Not used by the code under test.
@discardableResult
func runFixtureTool(_ path: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ToolError(description: "\(path) \(arguments.joined(separator: " ")) failed: \(output)")
    }
    return output
}

/// Builds small `.app` bundles inside a fixture tree.
enum FixtureApp {
    static let ourID = "com.iant4093.TruongCleaner"

    /// What goes into the bundle.
    struct Spec {
        var bundleID = FixtureApp.ourID
        var build = 2000
        var minimumSystem = "26.0"
        var architecture = "arm64"
        /// Ad-hoc sign the bundle (`codesign -s -`).
        var sign = true
    }

    /// A bundle with a compiled executable and an `Info.plist`, ad-hoc signed unless the spec says no.
    /// - Parameter path: Relative path inside the tree, ending in `.app`.
    @discardableResult
    static func make(in tree: FixtureTree, at path: String, _ spec: Spec = Spec()) throws -> URL {
        let app = try stub(in: tree, at: path, bundleID: spec.bundleID, build: spec.build, minimumSystem: spec.minimumSystem)
        let source = try tree.addFile("tools/\(UUID().uuidString).c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        let executable = app.appending(path: "Contents/MacOS/TruongCleaner")
        try tree.addDirectory("\(path)/Contents/MacOS")
        try runFixtureTool(
            "/usr/bin/clang",
            ["-arch", spec.architecture, "-o", executable.path(percentEncoded: false), source.path(percentEncoded: false)])
        if spec.sign {
            try runFixtureTool("/usr/bin/codesign", ["--force", "--sign", "-", app.path(percentEncoded: false)])
        }
        return app
    }

    /// A folder with only `Contents/Info.plist`: enough to read a bundle identifier.
    @discardableResult
    static func stub(
        in tree: FixtureTree, at path: String, bundleID: String = ourID, build: Int = 2000,
        minimumSystem: String = "26.0"
    ) throws -> URL {
        let plistURL = try tree.addFile("\(path)/Contents/Info.plist")
        let plist: [String: Any] = [
            "CFBundleExecutable": "TruongCleaner",
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "TruongCleaner",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": String(build),
            "LSMinimumSystemVersion": minimumSystem,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        return tree.url(for: path)
    }

    /// `CFBundleVersion` of the bundle at `url`, or `nil`.
    static func build(of url: URL) -> Int? {
        // Read the file itself: Bundle caches its Info.plist by path, which hides a swap.
        let plist = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) as? [String: Any]
        return (plist?["CFBundleVersion"] as? String).flatMap { Int($0) }
    }

    /// Flips one byte inside the first page of the executable, which the signature covers.
    static func tamper(_ app: URL) throws {
        let executable = app.appending(path: "Contents/MacOS/TruongCleaner")
        var data = try Data(contentsOf: executable)
        guard data.count > 9000 else { throw ToolError(description: "fixture executable is too small") }
        data[8000] ^= 0xFF
        try data.write(to: executable)
    }

    /// Zips the contents of `folder` (so `TruongCleaner.app` is at the top level) into `zip`.
    static func zip(contentsOf folder: URL, to zip: URL) throws {
        try runFixtureTool(
            "/usr/bin/ditto", ["-c", "-k", folder.path(percentEncoded: false), zip.path(percentEncoded: false)])
    }
}

extension UpdateIdentity {
    /// A running app at build 1000 on macOS 26.
    static let fixture = UpdateIdentity(
        bundleIdentifier: FixtureApp.ourID, bundleVersion: 1000, system: SystemVersion(major: 26))
}

/// A release's asset addresses, on the allow-list.
enum FixtureAssets {
    static let archiveURL = URL(string: "https://github.com/iant4093/TruongCleaner/releases/download/build-21/TruongCleaner.zip")!
    static let checksumsURL = URL(string: "https://github.com/iant4093/TruongCleaner/releases/download/build-21/SHA256SUMS")!
    static let signatureURL = URL(string: "https://github.com/iant4093/TruongCleaner/releases/download/build-21/SHA256SUMS.sig")!

    /// The release's assets; `signed: false` leaves out the signature address.
    static func make(signed: Bool = true) throws -> UpdateAssets {
        try #require(
            UpdateAssets(archive: archiveURL, checksums: checksumsURL, signature: signed ? signatureURL : nil))
    }

    /// `shasum -a 256` output for `data`, named `TruongCleaner.zip`.
    static func checksumLine(for data: Data, name: String = "TruongCleaner.zip") -> String {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(hex)  \(name)\n"
    }
}

/// A throwaway Ed25519 key for one test. Nothing here touches the Keychain.
struct FixtureSigner {
    let key = Curve25519.Signing.PrivateKey()

    /// Trusts only this signer's public key.
    var trust: UpdateTrust { UpdateTrust(publicKeys: [key.publicKey]) }

    /// Contents of a `SHA256SUMS.sig` for `message`: base64 of the signature and a newline.
    func signatureFile(for message: Data) throws -> Data {
        Data((try key.signature(for: message).base64EncodedString() + "\n").utf8)
    }
}

/// Serves fixture bytes instead of using the network. Records which addresses were asked for.
struct FakeFetcher: UpdateFetcher {
    var files: [URL: Data]
    var delay: Duration = .zero
    private let requested = OSAllocatedUnfairLock<[URL]>(initialState: [])

    /// - Parameter signature: Served as `SHA256SUMS.sig` when given.
    init(archive: Data, checksums: Data, signature: Data? = nil, delay: Duration = .zero) {
        files = [FixtureAssets.archiveURL: archive, FixtureAssets.checksumsURL: checksums]
        if let signature { files[FixtureAssets.signatureURL] = signature }
        self.delay = delay
    }

    var requestedURLs: [URL] { requested.withLock { $0 } }

    func fetch(
        _ url: URL, to destination: URL, maxBytes: Int64,
        progress: @Sendable (Int64, Int64?) -> Void
    ) async throws {
        requested.withLock { $0.append(url) }
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let data = files[url] else { throw UpdateError.downloadFailed("not found") }
        // Like the real fetcher: a body over the limit is an error.
        guard Int64(data.count) <= maxBytes else { throw UpdateError.downloadFailed("the file is too large") }
        let size = Int64(data.count)
        progress(size / 2, size)
        try data.write(to: destination)
        progress(size, size)
    }
}


/// Real file moves, except the listed calls (1-based) fail. A failing second move can leave a
/// half-copied folder at the destination first, as the cross-volume copy fallback does.
struct FlakyFileOperations: UpdateFileOperations {
    var failingMoves: Set<Int>
    var leavePartialCopy = false
    /// The partial copy has an `Info.plist` with this bundle identifier.
    var partialBundleID: String?
    /// The failure is reported as a failed cross-volume copy (`UpdateCopyFallbackError`).
    var copyFallback = false
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    private let removals = OSAllocatedUnfairLock<[URL]>(initialState: [])
    private let real = SystemUpdateFileOperations()

    init(
        failingMoves: Set<Int>, leavePartialCopy: Bool = false, partialBundleID: String? = nil,
        copyFallback: Bool = false
    ) {
        self.failingMoves = failingMoves
        self.leavePartialCopy = leavePartialCopy
        self.partialBundleID = partialBundleID
        self.copyFallback = copyFallback
    }

    /// Every URL passed to `removePartialCopy`.
    var removed: [URL] { removals.withLock { $0 } }

    func move(_ source: URL, to destination: URL) throws {
        let number = calls.withLock { count -> Int in
            count += 1
            return count
        }
        if failingMoves.contains(number) {
            if leavePartialCopy {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                if let partialBundleID {
                    let plist = destination.appending(path: "Contents/Info.plist")
                    try FileManager.default.createDirectory(
                        at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try PropertyListSerialization.data(
                        fromPropertyList: ["CFBundleIdentifier": partialBundleID], format: .xml, options: 0
                    ).write(to: plist)
                }
            }
            let failure = CocoaError(.fileWriteNoPermission)
            throw copyFallback ? UpdateCopyFallbackError(underlying: failure) : failure
        }
        try real.move(source, to: destination)
    }

    func itemExists(at url: URL) -> Bool { real.itemExists(at: url) }

    func removePartialCopy(at url: URL) throws {
        removals.withLock { $0.append(url) }
        try real.removePartialCopy(at: url)
    }
}

/// Stands in for the Trash: records moves and does not touch any file.
final class RecordingExecutor: ItemExecutor, Sendable {
    private let moved = OSAllocatedUnfairLock<[URL]>(initialState: [])
    private let deleted = OSAllocatedUnfairLock<[URL]>(initialState: [])

    var trashed: [URL] { moved.withLock { $0 } }
    var deletedPermanently: [URL] { deleted.withLock { $0 } }

    func moveToTrash(_ url: URL) async throws -> URL {
        moved.withLock { $0.append(url) }
        return url
    }

    func deletePermanently(_ url: URL) async throws {
        deleted.withLock { $0.append(url) }
    }
}

/// Runs `body` with a fresh fixture tree and removes the tree afterwards.
func withUpdateTree<T>(_ body: (FixtureTree) async throws -> T) async throws -> T {
    let tree = try FixtureTree()
    defer { tree.remove() }
    return try await body(tree)
}

/// Names of the `TruongCleanerUpdate-*` folders directly inside `folder`.
func updateFolders(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
        .filter { $0.hasPrefix(UpdateWorkspace.folderPrefix) }
}
