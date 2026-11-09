import Foundation

/// Where an update may be downloaded from.
///
/// Release assets live at `https://github.com/iant4093/TruongCleaner/releases/download/…`.
/// GitHub redirects those to its own asset hosts, so redirects may also land on the hosts in
/// ``redirectHosts``. Everything else is refused: other schemes, hosts, ports, user info and paths
/// with `..`.
public enum UpdateURLPolicy {
    /// Host of the release page and the first download address.
    public static let releaseHost = "github.com"
    /// Path every release asset address starts with.
    public static let releasePathPrefix = "/iant4093/TruongCleaner/releases/download/"
    /// GitHub's asset hosts, reached by redirect only.
    /// `release-assets.githubusercontent.com` is where GitHub redirects today (checked 2026-11-09);
    /// `objects.githubusercontent.com` is its older name.
    public static let redirectHosts: Set<String> = [
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    /// Whether `url` may be the address of a release asset (the address read from the release JSON).
    public static func isAllowedAssetURL(_ url: URL) -> Bool {
        guard isPlainHTTPS(url), host(of: url) == releaseHost else { return false }
        let path = url.path(percentEncoded: false)
        return path.hasPrefix(releasePathPrefix) && path.count > releasePathPrefix.count
    }

    /// Whether a redirect may go to `url`: an allowed asset address or one of ``redirectHosts``.
    public static func isAllowedRedirect(_ url: URL) -> Bool {
        if isAllowedAssetURL(url) { return true }
        guard isPlainHTTPS(url), let host = host(of: url) else { return false }
        return redirectHosts.contains(host)
    }

    private static func host(of url: URL) -> String? {
        url.host(percentEncoded: false)?.lowercased()
    }

    /// https, no user info, default port, no `..` segment.
    private static func isPlainHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user() == nil, url.password() == nil,
              url.port == nil || url.port == 443
        else { return false }
        return !url.path(percentEncoded: false).split(separator: "/").contains("..")
    }
}

/// The two files an update needs, both on the allow-list.
public struct UpdateAssets: Sendable, Equatable {
    /// Address of `TruongCleaner.zip`.
    public let archive: URL
    /// Address of `SHA256SUMS`.
    public let checksums: URL

    /// Returns `nil` unless both addresses pass ``UpdateURLPolicy/isAllowedAssetURL(_:)``.
    public init?(archive: URL, checksums: URL) {
        guard UpdateURLPolicy.isAllowedAssetURL(archive), UpdateURLPolicy.isAllowedAssetURL(checksums) else {
            return nil
        }
        self.archive = archive
        self.checksums = checksums
    }
}
