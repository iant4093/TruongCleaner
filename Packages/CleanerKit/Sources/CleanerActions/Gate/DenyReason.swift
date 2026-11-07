import CleanerCore
import Foundation

/// Why `SafetyGate` refused an item. Every case means "keep the item".
public enum DenyReason: Sendable, Codable, Hashable {
    /// The rule is an Info rule or has no action.
    case infoRule
    /// The item is in, or contains, a folder the user excluded.
    case userExcluded
    /// The item is not inside the rule's roots after resolving `..` and the parent's real path.
    case outsideRoots
    /// The item is a rule root, `~`, `~/Library` or another folder we never delete itself.
    case isRoot
    /// The global protected list covers the item.
    case protectedPath(ProtectedReason)
    /// A folder between the rule root and the item is a symbolic link.
    case symlinkAncestor
    /// The item is a code bundle or lies inside one.
    case insideBundle
    /// File flags (`SF_RESTRICTED`, `SF_NOUNLINK`, immutable, append-only) forbid removal.
    case macOSProtected
    /// The item's `(fsid, fileID)` differs from the scan.
    case changedSinceScan
    /// The item no longer exists.
    case missing
    /// The item is newer than the rule's `minAge`.
    case tooNew
    /// The rule has a `minAge` and the item's age could not be read completely.
    case unknownAge
    /// The item is among the newest of its folder, which the rule keeps.
    case keepNewest
    /// The owner app or process is running. Holds a name to show.
    case ownerOpen(String)
    /// Whether the owner is running could not be determined.
    case ownerUnknown
    /// A process has a file open inside the item.
    case openFiles
    /// Whether a process has a file open inside the item could not be determined.
    case openFilesUnknown
    /// A system call or probe failed, so the item is kept. Holds technical detail without paths.
    case probeFailed(String)

    /// A short sentence in plain words for the result list.
    public var userMessage: String {
        switch self {
        case .infoRule: "Shown for information only"
        case .userExcluded: "You excluded this folder"
        case .outsideRoots: "Outside the folders this rule cleans"
        case .isRoot: "This folder is kept; only what is inside it can be removed"
        case .protectedPath(let reason): Self.message(for: reason)
        case .symlinkAncestor: "A folder on its path is a link, so it was left alone"
        case .insideBundle: "Part of an app or plug-in, which is never edited"
        case .macOSProtected: "Protected by macOS"
        case .changedSinceScan: "Changed since the scan"
        case .missing: "Already gone"
        case .tooNew: "Used too recently"
        case .unknownAge: "Its age could not be checked"
        case .keepNewest: "One of the newest, which are kept"
        case .ownerOpen(let name): "\(name) is open"
        case .ownerUnknown: "Could not tell whether its app is open"
        case .openFiles: "In use by a running app"
        case .openFilesUnknown: "Could not check whether it is in use"
        case .probeFailed: "A safety check failed, so it was kept"
        }
    }

    private static func message(for reason: ProtectedReason) -> String {
        switch reason {
        case .system: "Protected system folder"
        case .root: "This folder is kept; only what is inside it can be removed"
        case .appleData: "Holds your Apple app data"
        case .syncAndIdentity: "Holds iCloud, keychain or account data"
        case .fragileAppleCache: "A system cache that macOS needs"
        case .agentState: "Holds AI assistant data"
        case .liveStore: "A store that tools use directly"
        case .licensedVendor: "Belongs to licensed software"
        case .passwordManager: "Belongs to a password manager or wallet"
        case .userExcluded: "You excluded this folder"
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case kind
        case detail
    }

    /// Decodes a reason written by `encode(to:)`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let detail = try container.decodeIfPresent(String.self, forKey: .detail)
        switch kind {
        case "infoRule": self = .infoRule
        case "userExcluded": self = .userExcluded
        case "outsideRoots": self = .outsideRoots
        case "isRoot": self = .isRoot
        case "protectedPath":
            guard let detail, let reason = ProtectedReason(codingName: detail) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .detail, in: container, debugDescription: "Unknown protected reason")
            }
            self = .protectedPath(reason)
        case "symlinkAncestor": self = .symlinkAncestor
        case "insideBundle": self = .insideBundle
        case "macOSProtected": self = .macOSProtected
        case "changedSinceScan": self = .changedSinceScan
        case "missing": self = .missing
        case "tooNew": self = .tooNew
        case "unknownAge": self = .unknownAge
        case "keepNewest": self = .keepNewest
        case "ownerOpen": self = .ownerOpen(detail ?? "")
        case "ownerUnknown": self = .ownerUnknown
        case "openFiles": self = .openFiles
        case "openFilesUnknown": self = .openFilesUnknown
        case "probeFailed": self = .probeFailed(detail ?? "")
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "Unknown deny reason \(kind)")
        }
    }

    /// Encodes the reason as `{"kind": ..., "detail": ...}`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let (kind, detail): (String, String?) = switch self {
        case .infoRule: ("infoRule", nil)
        case .userExcluded: ("userExcluded", nil)
        case .outsideRoots: ("outsideRoots", nil)
        case .isRoot: ("isRoot", nil)
        case .protectedPath(let reason): ("protectedPath", reason.codingName)
        case .symlinkAncestor: ("symlinkAncestor", nil)
        case .insideBundle: ("insideBundle", nil)
        case .macOSProtected: ("macOSProtected", nil)
        case .changedSinceScan: ("changedSinceScan", nil)
        case .missing: ("missing", nil)
        case .tooNew: ("tooNew", nil)
        case .unknownAge: ("unknownAge", nil)
        case .keepNewest: ("keepNewest", nil)
        case .ownerOpen(let name): ("ownerOpen", name)
        case .ownerUnknown: ("ownerUnknown", nil)
        case .openFiles: ("openFiles", nil)
        case .openFilesUnknown: ("openFilesUnknown", nil)
        case .probeFailed(let detail): ("probeFailed", detail)
        }
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(detail, forKey: .detail)
    }
}

/// `ProtectedReason` is not `Codable` in CleanerCore, so the gate stores it by name.
extension ProtectedReason {
    fileprivate var codingName: String {
        switch self {
        case .system: "system"
        case .root: "root"
        case .appleData: "appleData"
        case .syncAndIdentity: "syncAndIdentity"
        case .fragileAppleCache: "fragileAppleCache"
        case .agentState: "agentState"
        case .liveStore: "liveStore"
        case .licensedVendor: "licensedVendor"
        case .passwordManager: "passwordManager"
        case .userExcluded: "userExcluded"
        }
    }

    fileprivate init?(codingName: String) {
        switch codingName {
        case "system": self = .system
        case "root": self = .root
        case "appleData": self = .appleData
        case "syncAndIdentity": self = .syncAndIdentity
        case "fragileAppleCache": self = .fragileAppleCache
        case "agentState": self = .agentState
        case "liveStore": self = .liveStore
        case "licensedVendor": self = .licensedVendor
        case "passwordManager": self = .passwordManager
        case "userExcluded": self = .userExcluded
        default: return nil
        }
    }
}

/// The gate's decision for one item.
public enum Verdict: Sendable, Equatable {
    /// Every check passed. The caller may act on the item now.
    case allow
    /// A check failed. The item is kept, for this reason.
    case deny(DenyReason)
}
