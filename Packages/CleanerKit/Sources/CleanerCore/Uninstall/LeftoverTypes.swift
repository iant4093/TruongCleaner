import Foundation

/// A folder under a `Library` where an app may leave files (`docs/UNINSTALLER.md` §2).
public enum LeftoverFolder: String, Sendable, Hashable, CaseIterable {
    case applicationSupport
    case caches
    case containers
    case groupContainers
    case preferences
    case preferencesByHost
    case savedState
    case httpStorages
    case webKit
    case logs
    case launchAgents
    case applicationScripts
    case cookies
    /// `/Library` only.
    case launchDaemons
    /// `/Library` only.
    case privilegedHelperTools

    /// Path components below `Library`.
    public var components: [String] {
        switch self {
        case .applicationSupport: ["Application Support"]
        case .caches: ["Caches"]
        case .containers: ["Containers"]
        case .groupContainers: ["Group Containers"]
        case .preferences: ["Preferences"]
        case .preferencesByHost: ["Preferences", "ByHost"]
        case .savedState: ["Saved Application State"]
        case .httpStorages: ["HTTPStorages"]
        case .webKit: ["WebKit"]
        case .logs: ["Logs"]
        case .launchAgents: ["LaunchAgents"]
        case .applicationScripts: ["Application Scripts"]
        case .cookies: ["Cookies"]
        case .launchDaemons: ["LaunchDaemons"]
        case .privilegedHelperTools: ["PrivilegedHelperTools"]
        }
    }

    /// The folder's name for the screen.
    public var title: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .preferences: "Preferences"
        case .preferencesByHost: "Preferences (this Mac)"
        case .savedState: "Saved window state"
        case .httpStorages: "Web storage"
        case .webKit: "WebKit data"
        case .logs: "Logs"
        case .launchAgents: "Launch agents"
        case .applicationScripts: "Application scripts"
        case .cookies: "Cookies"
        case .launchDaemons: "Launch daemons"
        case .privilegedHelperTools: "Privileged helper tools"
        }
    }

    /// Folders of the user's own `~/Library` that are searched and may be cleaned.
    public static let userFolders: [LeftoverFolder] = [
        .applicationSupport, .caches, .containers, .groupContainers, .preferences, .preferencesByHost,
        .savedState, .httpStorages, .webKit, .logs, .launchAgents, .applicationScripts, .cookies,
    ]

    /// Folders of `/Library` that are searched and shown only.
    public static let systemFolders: [LeftoverFolder] = userFolders + [.launchDaemons, .privilegedHelperTools]

    /// Whether the entries are launchd jobs, read from their plists.
    public var holdsLaunchJobs: Bool {
        self == .launchAgents || self == .launchDaemons
    }
}

/// Whose `Library` a folder belongs to.
public enum LeftoverScope: String, Sendable, Hashable, CaseIterable {
    /// `~/Library`. Items can be cleaned.
    case user
    /// `/Library`. Items are shown and never deleted (they need an administrator).
    case system
}

/// One searched folder: a `Library` folder in a scope.
public struct LeftoverPlace: Sendable, Hashable {
    /// `~/Library` or `/Library`.
    public var scope: LeftoverScope
    /// The folder below it.
    public var folder: LeftoverFolder

    /// Creates a place.
    public init(scope: LeftoverScope, folder: LeftoverFolder) {
        self.scope = scope
        self.folder = folder
    }

    /// Every place that is searched, user folders first.
    public static var all: [LeftoverPlace] {
        LeftoverFolder.userFolders.map { LeftoverPlace(scope: .user, folder: $0) }
            + LeftoverFolder.systemFolders.map { LeftoverPlace(scope: .system, folder: $0) }
    }

    /// The folder's name for the screen. `/Library` folders say "all users".
    public var title: String {
        scope == .user ? folder.title : "\(folder.title) (all users)"
    }
}

/// What the finder read from a launchd job plist.
public struct LaunchJob: Sendable, Hashable {
    /// The job's `Label`.
    public var label: String?
    /// Every executable path the plist names: `Program` and the first item of `ProgramArguments`.
    public var programs: [String]

    /// Creates a launch job.
    public init(label: String?, programs: [String]) {
        self.label = label
        self.programs = programs
    }
}

/// One direct child of a searched folder, with the facts the matcher needs and nothing else.
public struct LeftoverEntry: Sendable, Hashable {
    /// The name as the file system gives it.
    public var name: String
    /// Whether it is a real folder (a symbolic link is not).
    public var isDirectory: Bool
    /// `MCMMetadataIdentifier` of a container, for containers whose name is not a bundle ID.
    public var metadataIdentifier: String?
    /// The plist of a launch agent or daemon.
    public var launchJob: LaunchJob?
    /// What the folder holds, when the caller measured it. Nil means not measured.
    public var contents: LeftoverContents?

    /// Creates an entry.
    public init(
        name: String, isDirectory: Bool = true, metadataIdentifier: String? = nil, launchJob: LaunchJob? = nil,
        contents: LeftoverContents? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.metadataIdentifier = metadataIdentifier
        self.launchJob = launchJob
        self.contents = contents
    }
}

/// What a candidate folder holds, as far as the caller could tell. A field that is nil was not measured.
public struct LeftoverContents: Sendable, Hashable {
    /// Allocated bytes of the whole folder.
    public var allocatedBytes: Int64?
    /// Whether `Data/Documents` (a container's document folder) holds anything.
    public var hasDocuments: Bool?
    /// Whether the folder holds a virtual machine or disk image anywhere inside (see
    /// `LeftoverMatcher.isVirtualMachineOrDiskImage(name:allocatedBytes:)`).
    public var hasDiskImages: Bool?

    /// Creates a description.
    public init(allocatedBytes: Int64? = nil, hasDocuments: Bool? = nil, hasDiskImages: Bool? = nil) {
        self.allocatedBytes = allocatedBytes
        self.hasDocuments = hasDocuments
        self.hasDiskImages = hasDiskImages
    }

    /// Whether every field was measured.
    public var isComplete: Bool {
        allocatedBytes != nil && hasDocuments != nil && hasDiskImages != nil
    }
}

/// A reason to look at a folder before removing it, which makes a matched folder `.review`.
public enum LeftoverWarning: Sendable, Hashable {
    /// It holds a virtual machine or a disk image (`Docker.raw`, `*.utm`, `*.pvm`, `*.vmwarevm`, `data.img`,
    /// `*.sparsebundle`, `*.dmg`). Docker volumes and VM disks hold data nobody can rebuild.
    case virtualMachinesOrDiskImages
    /// `Data/Documents` is not empty.
    case documents
    /// It is larger than ``LeftoverMatcher/largeFolderBytes``.
    case large
    /// What is inside could not be read, so the check for other apps' files could not run.
    case unreadable

    /// One plain sentence for the screen.
    public var text: String {
        switch self {
        case .virtualMachinesOrDiskImages: "Contains virtual machines or disk images."
        case .documents: "Contains documents."
        case .large: "It is larger than 1 GB."
        case .unreadable: "What is inside could not be read."
        }
    }
}

/// Why an entry belongs to an app.
public enum LeftoverEvidence: Sendable, Hashable {
    /// The name is the bundle ID.
    case exactBundleID(String)
    /// The name is the bundle ID plus a suffix.
    case bundleIDPrefix(String)
    /// A container whose metadata names the bundle ID.
    case containerMetadata(String)
    /// A group container named after the bundle ID.
    case groupContainerBundleID(String)
    /// A group container that starts with the developer's team ID.
    case groupContainerTeamID(String)
    /// A launchd job with the bundle ID as label that runs a program inside the app.
    case launchJob(label: String)
    /// A launchd job with the bundle ID as label (shown only; its program was not required).
    case launchJobLabel(label: String)
    /// The name is the app's name.
    case appName(String)
    /// The base evidence, plus a reason to look before removing. The folder is `.review`.
    indirect case withWarning(LeftoverWarning, LeftoverEvidence)

    /// One plain sentence for the screen.
    public var text: String {
        switch self {
        case .withWarning(let warning, let base): "\(base.text) \(warning.text)"
        case .exactBundleID(let id): "Named after the app’s ID, \(id)."
        case .bundleIDPrefix(let id): "Name starts with the app’s ID, \(id)."
        case .containerMetadata(let id): "Container that belongs to \(id), by its own record."
        case .groupContainerBundleID(let id): "Group container named after \(id)."
        case .groupContainerTeamID(let team):
            "Group container of developer \(team). It may also be used by that developer’s other apps."
        case .launchJob(let label): "Launch job “\(label)” that runs a program inside the app."
        case .launchJobLabel(let label): "Launch job “\(label)”."
        case .appName(let name): "Named like the app, “\(name)”. Check that it is yours before you remove it."
        }
    }
}

/// One entry the matcher says belongs to the app.
public struct LeftoverCandidate: Sendable, Hashable, Identifiable {
    /// The folder it lies in.
    public var place: LeftoverPlace
    /// Its name.
    public var name: String
    /// `.safe` is selected by default, `.review` is not, `.info` is shown only (`/Library`).
    public var tier: Tier
    /// Why it belongs to the app.
    public var evidence: LeftoverEvidence

    /// Creates a candidate.
    public init(place: LeftoverPlace, name: String, tier: Tier, evidence: LeftoverEvidence) {
        self.place = place
        self.name = name
        self.tier = tier
        self.evidence = evidence
    }

    /// Place and name together.
    public var id: String { "\(place.scope.rawValue)/\(place.folder.rawValue)/\(name)" }
}

/// The matcher's answer.
public struct LeftoverMatches: Sendable {
    /// Entries that belong to the app, in folder order and then by name.
    public var candidates: [LeftoverCandidate]
    /// A sentence to show when matching was limited, or nil.
    public var notice: String?

    /// Creates an answer.
    public init(candidates: [LeftoverCandidate], notice: String? = nil) {
        self.candidates = candidates
        self.notice = notice
    }
}
