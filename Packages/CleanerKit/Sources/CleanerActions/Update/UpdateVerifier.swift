import Darwin
import Foundation
import Security

/// A macOS version as three numbers, for the `LSMinimumSystemVersion` check.
public struct SystemVersion: Sendable, Equatable, Comparable {
    /// Major version, for example 26.
    public var major: Int
    /// Minor version.
    public var minor: Int
    /// Patch version.
    public var patch: Int

    /// Creates a version from its parts.
    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `"26"`, `"26.0"` or `"26.0.1"`. Returns `nil` for anything else.
    public init?(string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let numbers = parts.compactMap { $0 }
        self.init(major: numbers[0], minor: numbers.count > 1 ? numbers[1] : 0, patch: numbers.count > 2 ? numbers[2] : 0)
    }

    /// The macOS version this process runs on.
    public static var running: SystemVersion {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SystemVersion(major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion)
    }

    /// Orders by major, then minor, then patch.
    public static func < (lhs: SystemVersion, rhs: SystemVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// Text such as `26.0` or `26.0.1`.
    public var text: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }
}

/// Who is asking: the running app's identity, which an update must match and exceed.
public struct UpdateIdentity: Sendable, Equatable {
    /// `CFBundleIdentifier` of the running app.
    public var bundleIdentifier: String
    /// `CFBundleVersion` of the running app (the build number).
    public var bundleVersion: Int
    /// macOS version of the running system.
    public var system: SystemVersion

    /// Creates an identity. Tests pass fixed values.
    public init(bundleIdentifier: String, bundleVersion: Int, system: SystemVersion) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleVersion = bundleVersion
        self.system = system
    }

    /// The identity of `bundle`, or `nil` when its identifier or build number cannot be read.
    public static func current(bundle: Bundle = .main) -> UpdateIdentity? {
        guard let identifier = bundle.bundleIdentifier,
              let version = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap({ Int($0) })
        else { return nil }
        return UpdateIdentity(bundleIdentifier: identifier, bundleVersion: version, system: .running)
    }
}

/// An unpacked update that passed every check and is ready to swap in.
public struct VerifiedUpdate: Sendable, Equatable {
    /// The new `TruongCleaner.app`.
    public let app: URL
    /// Its `CFBundleVersion`.
    public let bundleVersion: Int
}

/// Checks an unpacked app before it replaces the running one.
public struct UpdateVerifier: Sendable {
    /// Creates a verifier.
    public init() {}

    /// Runs the checks in order, cheapest first, and stops at the first failure:
    /// bundle identifier, build number, minimum macOS, arm64 code, then the code signature
    /// (`SecStaticCodeCheckValidity` with strict validation; an ad-hoc signature passes if intact).
    /// On success it removes `com.apple.quarantine` from the bundle.
    ///
    /// Anything unreadable or unparseable fails the check (unknown means keep the old app).
    @concurrent
    public func verify(_ app: URL, against identity: UpdateIdentity) async throws -> VerifiedUpdate {
        guard let bundle = Bundle(url: app), let info = bundle.infoDictionary else {
            throw UpdateError.unreadableBundle
        }
        guard info["CFBundleIdentifier"] as? String == identity.bundleIdentifier else {
            throw UpdateError.wrongBundleIdentifier
        }
        guard let version = (info["CFBundleVersion"] as? String).flatMap({ Int($0) }) else {
            throw UpdateError.unreadableBundle
        }
        guard version > identity.bundleVersion else { throw UpdateError.notNewer }

        guard let minimumText = info["LSMinimumSystemVersion"] as? String,
              let minimum = SystemVersion(string: minimumText)
        else { throw UpdateError.unreadableBundle }
        guard minimum <= identity.system else { throw UpdateError.needsNewerSystem(minimum.text) }

        guard let architectures = bundle.executableArchitectures else { throw UpdateError.unreadableBundle }
        guard architectures.contains(where: { $0.intValue == NSBundleExecutableArchitectureARM64 }) else {
            throw UpdateError.wrongArchitecture
        }

        try Self.checkSignature(of: app)
        Self.removeQuarantine(from: app)
        return VerifiedUpdate(app: app, bundleVersion: version)
    }

    // MARK: Internal

    /// Strict validation of every architecture and nested code. No network (no revocation check).
    static func checkSignature(of app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else {
            throw UpdateError.invalidSignature
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode))
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
            throw UpdateError.invalidSignature
        }
    }

    /// Removes the quarantine attribute from `root` and everything below it, without following
    /// links and without running `xattr`. A missing attribute is fine; other errors are ignored,
    /// because the app was already verified and a leftover flag only means a Gatekeeper prompt.
    static func removeQuarantine(from root: URL) {
        let name = "com.apple.quarantine"
        _ = removexattr(UpdateWorkspace.unixPath(root), name, XATTR_NOFOLLOW)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker {
            _ = removexattr(url.path(percentEncoded: false), name, XATTR_NOFOLLOW)
        }
    }
}
