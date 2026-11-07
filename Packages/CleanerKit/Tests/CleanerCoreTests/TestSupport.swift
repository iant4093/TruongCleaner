import Foundation
@testable import CleanerCore

/// Pure values for tests in this target. Nothing here touches the file system:
/// the "home" is just a path used as text.
enum TestEnv {
    static let homePath = "/Users/tester"
    static let home = URL(filePath: homePath, directoryHint: .isDirectory)
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// The one project folder the user "chose" in tests.
    static let projectFolder = URL(filePath: "/Users/tester/Code", directoryHint: .isDirectory)

    static func environment(now: Date = TestEnv.now, projectFolders: [URL] = [TestEnv.projectFolder]) -> Environment {
        Environment(
            home: home,
            darwinUserCache: URL(filePath: "/private/var/folders/ab/cdef/C", directoryHint: .isDirectory),
            darwinUserTemp: URL(filePath: "/private/var/folders/ab/cdef/T", directoryHint: .isDirectory),
            now: now,
            projectFolders: projectFolders
        )
    }

    static func policy(exclusions: [URL] = []) -> PathPolicy {
        PathPolicy(environment: environment(), userExclusions: exclusions)
    }

    /// Turns `~/x` into a URL under the test home; other paths stay absolute.
    static func url(_ path: String) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return URL(filePath: homePath + String(path.dropFirst(1))) }
        return URL(filePath: path)
    }

    static func days(_ count: Double) -> Date {
        now.addingTimeInterval(-count * 86_400)
    }
}
