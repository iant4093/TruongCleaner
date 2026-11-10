import CleanerCore
import Foundation
import Security

/// Answers whether an app was signed by Apple itself. The gate asks it for `installers.macOS`.
public protocol AppSignatureChecker: Sendable {
    /// `true` when the app satisfies `anchor apple`, `false` when it is unsigned or signed by anyone
    /// else, nil when this could not be determined. Nil keeps the item.
    func isAppleSigned(_ app: URL) -> Bool?
}

/// The production checker. It uses the Security framework (no `codesign`, no `Process`).
public struct SecurityAppSignatureChecker: AppSignatureChecker {
    /// Creates a checker.
    public init() {}

    /// Checks the signature structure against the requirement `anchor apple`. It does not hash every
    /// file, so a 12 GB installer is checked in moments.
    public func isAppleSigned(_ app: URL) -> Bool? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
            let staticCode
        else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, SecCSFlags(), &requirement) == errSecSuccess,
            let requirement
        else { return nil }
        switch SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSBasicValidateOnly), requirement) {
        case errSecSuccess: return true
        case errSecCSReqFailed, errSecCSUnsigned: return false
        default: return nil
        }
    }
}

/// What the gate needs to know about a macOS installer app.
enum InstallerCheck {
    /// Every Apple installer app has a bundle ID that starts with this.
    static let bundleIDPrefix = "com.apple.InstallAssistant."

    /// The bundle ID in the app's own `Contents/Info.plist`. Nil when it is missing or unreadable.
    static func bundleID(of app: URL) -> String? {
        switch ProcessOwnerMatcher.readBundleID(atAppPath: app.path(percentEncoded: false)) {
        case .identifier(let id): id
        case .noBundle, .unreadable: nil
        }
    }
}
