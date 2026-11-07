import Foundation

/// Values the pure decision layer needs from the outside world.
///
/// Callers read them once (home folder, `getconf` directories, the clock) and
/// pass them in, so tests can use a fixture home and a fixed date.
public struct Environment: Sendable {
    /// The user's home folder. Tests pass a fixture home.
    public var home: URL
    /// `DARWIN_USER_CACHE_DIR`, or nil when it could not be read.
    public var darwinUserCache: URL?
    /// `DARWIN_USER_TEMP_DIR`, or nil when it could not be read.
    public var darwinUserTemp: URL?
    /// The current time. Item ages are measured against it.
    public var now: Date
    /// Folders the user chose for `RootSpec.Base.userChosen` rules (project folders). Empty by default.
    /// Folders the protected list covers, such as `~` or `~/Library`, are ignored.
    public var projectFolders: [URL]

    /// Creates an environment.
    public init(
        home: URL,
        darwinUserCache: URL? = nil,
        darwinUserTemp: URL? = nil,
        now: Date = Date(),
        projectFolders: [URL] = []
    ) {
        self.home = home
        self.darwinUserCache = darwinUserCache
        self.darwinUserTemp = darwinUserTemp
        self.now = now
        self.projectFolders = projectFolders
    }
}
