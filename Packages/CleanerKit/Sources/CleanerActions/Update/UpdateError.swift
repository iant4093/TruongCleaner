import Foundation

/// Why an in-app update stopped. Every case means "nothing was installed", except
/// ``swapFailed(_:restoredOldApp:)`` which says whether the old app is back in place.
/// The messages are shown to the user as they are.
public enum UpdateError: Error, Sendable, Equatable, LocalizedError {
    /// A download address is not on the allow-list (``UpdateURLPolicy``).
    case disallowedURL(String)
    /// The download failed. Holds a short reason.
    case downloadFailed(String)
    /// The download took longer than the time limit.
    case timedOut
    /// The user cancelled.
    case cancelled
    /// `SHA256SUMS` has no single line for the ZIP, or the line is malformed.
    case checksumMissing
    /// The ZIP does not match its line in `SHA256SUMS`.
    case checksumMismatch
    /// The release has no `SHA256SUMS.sig`, so nothing was downloaded.
    case unsigned
    /// `SHA256SUMS.sig` is malformed or not valid for any trusted key.
    case badSignature
    /// `ditto` could not unpack the ZIP. Holds a short reason.
    case unpackFailed(String)
    /// The ZIP holds something other than exactly one `TruongCleaner.app`.
    case unexpectedArchiveContents
    /// The new bundle's `Info.plist` or executable cannot be read.
    case unreadableBundle
    /// The new bundle has a different bundle identifier.
    case wrongBundleIdentifier
    /// The new bundle is not newer than the running app.
    case notNewer
    /// The new bundle needs a newer macOS. Holds the required version.
    case needsNewerSystem(String)
    /// The new executable does not contain arm64 code.
    case wrongArchitecture
    /// The new bundle's code signature is missing, broken or does not pass strict validation.
    case invalidSignature
    /// The running app is not directly inside `/Applications` or `~/Applications`.
    case installLocationNotSupported
    /// The folder that holds the running app is not writable.
    case notWritable
    /// The swap failed. `restoredOldApp` says whether the previous version is back at its path.
    case swapFailed(String, restoredOldApp: Bool)

    /// Plain-language text for the UI.
    public var errorDescription: String? {
        switch self {
        case .disallowedURL:
            "The update is not hosted where TruongCleaner expects it, so it was not downloaded."
        case .downloadFailed(let reason):
            "The update could not be downloaded (\(reason))."
        case .timedOut:
            "The download took longer than 5 minutes and was stopped."
        case .cancelled:
            "The update was cancelled."
        case .checksumMissing:
            "The release has no usable checksum for the update. Nothing was installed."
        case .checksumMismatch:
            "The download does not match its checksum. Nothing was installed."
        case .unsigned:
            "This update is not signed yet, so it was not installed. Try again later, or download it from the release page."
        case .badSignature:
            "The update's signature is not valid. Nothing was installed."
        case .unpackFailed(let reason):
            "The update could not be unpacked (\(reason))."
        case .unexpectedArchiveContents:
            "The download does not contain exactly one TruongCleaner app. Nothing was installed."
        case .unreadableBundle:
            "The downloaded app could not be read. Nothing was installed."
        case .wrongBundleIdentifier:
            "The download is not TruongCleaner. Nothing was installed."
        case .notNewer:
            "The download is not newer than this version. Nothing was installed."
        case .needsNewerSystem(let version):
            "The new version needs macOS \(version) or later."
        case .wrongArchitecture:
            "The new version is not built for Apple silicon. Nothing was installed."
        case .invalidSignature:
            "The new version's code signature is not valid. Nothing was installed."
        case .installLocationNotSupported:
            "TruongCleaner can only update itself when it is in the Applications folder."
        case .notWritable:
            "The folder that holds TruongCleaner is not writable, so it cannot update itself."
        case .swapFailed(let reason, let restored):
            restored
                ? "The update could not be installed (\(reason)). The old version was put back."
                : "The update could not be installed (\(reason)). Reinstall TruongCleaner from GitHub."
        }
    }
}
