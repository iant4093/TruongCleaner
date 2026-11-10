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

/// The files an update needs, all on the allow-list.
public struct UpdateAssets: Sendable, Equatable {
    /// Release asset name of the checksum list.
    public static let checksumsName = "SHA256SUMS"
    /// Release asset name of the detached Ed25519 signature over ``checksumsName``.
    public static let signatureName = "SHA256SUMS.sig"

    /// Address of `TruongCleaner.zip`.
    public let archive: URL
    /// Address of `SHA256SUMS`.
    public let checksums: URL
    /// Address of `SHA256SUMS.sig`, or `nil` when the release has none (it cannot be installed).
    public let signature: URL?

    /// Returns `nil` unless every given address passes ``UpdateURLPolicy/isAllowedAssetURL(_:)``.
    public init?(archive: URL, checksums: URL, signature: URL? = nil) {
        guard UpdateURLPolicy.isAllowedAssetURL(archive), UpdateURLPolicy.isAllowedAssetURL(checksums) else {
            return nil
        }
        if let signature, !UpdateURLPolicy.isAllowedAssetURL(signature) { return nil }
        self.archive = archive
        self.checksums = checksums
        self.signature = signature
    }

    /// Picks the update files out of a release's asset list (`name` and download address).
    ///
    /// The ZIP and `SHA256SUMS` must each appear exactly once. `SHA256SUMS.sig` must appear exactly
    /// once to count; zero or several mean "no signature". Returns `nil` when a needed address is
    /// missing, unreadable or not on the allow-list, including a present signature address.
    public static func select(from assets: [(name: String, address: String)]) -> UpdateAssets? {
        func addresses(of name: String) -> [String] {
            assets.filter { $0.name == name }.map(\.address)
        }
        let archives = addresses(of: UpdateDownloader.archiveName)
        let sums = addresses(of: checksumsName)
        let signatures = addresses(of: signatureName)
        guard archives.count == 1, sums.count == 1,
              let archive = URL(string: archives[0]), let checksums = URL(string: sums[0])
        else { return nil }
        guard signatures.count == 1 else {
            return UpdateAssets(archive: archive, checksums: checksums)
        }
        guard let signature = URL(string: signatures[0]) else { return nil }
        return UpdateAssets(archive: archive, checksums: checksums, signature: signature)
    }
}

