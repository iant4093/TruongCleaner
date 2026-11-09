import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Testing

@testable import CleanerScanner

/// A fixture machine for the uninstaller: `home`, `/Applications` and `/Library` stand-ins, all inside
/// one fixture tree. Nothing here touches the real home folder, `~/Library`, `/Library` or `/Applications`.
struct AppsHarness {
    let tree: FixtureTree
    let home: URL
    let applications: URL
    let userApplications: URL
    let systemLibrary: URL
    let userLibrary: URL

    init() throws {
        tree = try FixtureTree()
        home = try tree.addDirectory("home")
        userLibrary = try tree.addDirectory("home/Library")
        applications = try tree.addDirectory("Applications")
        userApplications = try tree.addDirectory("home/Applications")
        systemLibrary = try tree.addDirectory("Library")
    }

    func remove() { tree.remove() }

    var folders: [URL] { [applications, userApplications] }

    func context(ownBundleID: String? = "com.iant4093.TruongCleaner") -> UninstallContext {
        UninstallContext(
            home: home,
            systemLibrary: systemLibrary,
            applicationFolders: folders,
            ownBundleID: ownBundleID,
            currentUserID: UInt32(getuid()))
    }

    /// Writes a property list file, creating its folders. Returns its URL.
    @discardableResult
    func writePlist(_ relativePath: String, _ values: [String: Any]) throws -> URL {
        let url = try tree.addFile(relativePath, size: 0)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    /// Adds an unsigned `.app` with an `Info.plist` and an executable of `size` bytes.
    @discardableResult
    func addApp(
        _ relativeFolder: String = "Applications", file: String, bundleID: String?, name: String? = nil,
        executable: String? = nil, size: Int = 8_192
    ) throws -> URL {
        let base = "\(relativeFolder)/\(file).app"
        var plist: [String: Any] = ["CFBundleShortVersionString": "1.2"]
        if let bundleID { plist["CFBundleIdentifier"] = bundleID }
        plist["CFBundleName"] = name ?? file
        plist["CFBundleExecutable"] = executable ?? file
        try writePlist("\(base)/Contents/Info.plist", plist)
        try tree.addFile("\(base)/Contents/MacOS/\(executable ?? file)", size: size)
        return tree.url(for: base)
    }

    /// The facts of an app in a fresh inventory, found by its bundle ID.
    func inventory() async -> InstalledApps {
        await AppInventory.scan(folders: folders)
    }

    func app(_ bundleID: String, in inventory: InstalledApps) throws -> AppFacts {
        try #require(inventory.apps.first { $0.bundleID == bundleID }, "no app \(bundleID) in the inventory")
    }
}

/// Runs `body` with a fresh harness and removes the fixture afterwards.
func withAppsHarness(_ body: (AppsHarness) async throws -> Void) async throws {
    let harness = try AppsHarness()
    defer { harness.remove() }
    try await body(harness)
}
