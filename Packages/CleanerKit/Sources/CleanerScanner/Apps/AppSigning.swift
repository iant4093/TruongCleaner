import CleanerCore
import Foundation
import Security

/// Reads who signed an app with the Security framework (no `Process`, no `codesign`).
enum AppSigning {
    /// The signature facts the uninstaller needs.
    struct Info: Sendable, Equatable {
        var teamID: String?
        var signature: AppSignature
    }

    /// The team ID and whether Apple's own anchor signed the app.
    ///
    /// An unsigned app is `.other` with no team ID. Anything that cannot be read is `.unknown`; the
    /// eligibility check refuses such an app.
    static func read(_ app: URL) -> Info {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
            let staticCode
        else { return Info(teamID: nil, signature: .unknown) }

        var information: CFDictionary?
        let copied = SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        if copied == errSecCSUnsigned { return Info(teamID: nil, signature: .other) }
        guard copied == errSecSuccess, let dictionary = information as? [String: Any] else {
            return Info(teamID: nil, signature: .unknown)
        }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String

        // "anchor apple" is true only for software Apple itself signed. Developer ID apps fail it
        // (`errSecCSReqFailed`). The basic check reads the signature's structure and does not hash every file.
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, SecCSFlags(), &requirement) == errSecSuccess,
            let requirement
        else { return Info(teamID: team, signature: .unknown) }
        let check = SecStaticCodeCheckValidity(
            staticCode, SecCSFlags(rawValue: kSecCSBasicValidateOnly), requirement)
        switch check {
        case errSecSuccess: return Info(teamID: team, signature: .apple)
        case errSecCSReqFailed, errSecCSUnsigned: return Info(teamID: team, signature: .other)
        default: return Info(teamID: team, signature: .unknown)
        }
    }
}
