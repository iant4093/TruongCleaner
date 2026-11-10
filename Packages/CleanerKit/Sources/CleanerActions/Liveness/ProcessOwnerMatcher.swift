import CleanerCore
import Darwin
import Foundation

/// Finds running processes that belong to a rule's owner, by name, by argument vector or by bundle ID.
///
/// Many tools do not run under their own name: npm, yarn and pnpm run as `node`, CocoaPods as
/// `ruby`, Homebrew as `bash` or `ruby`, `swift build` as `swift-build`, and the Gradle daemon as
/// `java`. So a process matches a name when any of these is the name:
///
/// - its short name, or the last component of its executable path;
/// - the last component of `argv[0]`, or of `argv[1]` (with a script extension such as `.js`, `.cjs`,
///   `.mjs`, `.rb`, `.sh` removed), which is how an interpreter shows the script it runs;
/// - for a few names, a marker anywhere in the arguments (see ``argvMarkers``).
///
/// Unknown means keep: if the arguments of one of the user's own interpreter processes cannot be
/// read, the answer is `.unknown`, because that process could be the tool.
enum ProcessOwnerMatcher {
    /// Processes that run other programs. Their own name says nothing, so their arguments matter.
    static let interpreters: Set<String> = [
        "node", "ruby", "java", "bun", "deno", "python", "python3", "perl", "bash", "sh", "zsh",
    ]

    /// Strings in an argument vector that identify a tool whose process has another name.
    static let argvMarkers: [String: Set<String>] = [
        "gradle": [
            "org.gradle.launcher.daemon.bootstrap.GradleDaemon",
            "org.gradle.wrapper.GradleWrapperMain",
            "org.gradle.launcher.GradleMain",
        ]
    ]

    /// Script extensions removed from `argv[1]` before comparing.
    private static let scriptExtensions: Set<String> = ["js", "cjs", "mjs", "rb", "sh", "py", "pl"]

    // MARK: Pure matching

    /// Whether one process, described by its facts, is the tool called `name`.
    ///
    /// - Parameters:
    ///   - name: The owner's name, for example `npm`.
    ///   - shortName: The process's short name.
    ///   - executable: The process's executable path.
    ///   - argv: The process's argument vector, if it could be read.
    static func matches(name: String, shortName: String?, executable: String?, argv: [String]?) -> Bool {
        guard !name.isEmpty else { return false }
        let own = [shortName, executable.map(lastComponent)].compactMap { $0 }
        if own.contains(name) { return true }
        if name == "swift", own.contains(where: { $0.hasPrefix("swift-") }) { return true }
        guard let argv else { return false }
        if let first = argv.first {
            let base = lastComponent(first)
            if base == name || (name == "swift" && base.hasPrefix("swift-")) { return true }
        }
        if argv.count > 1 {
            let base = lastComponent(argv[1])
            if base == name || withoutScriptExtension(base) == name { return true }
        }
        if let markers = argvMarkers[name], argv.contains(where: markers.contains) { return true }
        return false
    }

    /// Whether a process of this kind could hide a tool in its arguments.
    static func isInterpreter(shortName: String?, executable: String?) -> Bool {
        let names = [shortName, executable.map(lastComponent)].compactMap { $0 }
        return names.contains { name in
            interpreters.contains(name) || name.hasPrefix("python") || name.hasPrefix("java")
        }
    }

    // MARK: Questions about the live process table

    /// Whether a process of the tool called `name` is running. `.unknown` when the process list
    /// cannot be read, or when an interpreter process of the current user could not be inspected.
    static func state(ofProcessNamed name: String) -> OwnerState {
        guard !name.isEmpty, let pids = ProcessTable.allPIDs() else { return .unknown }
        var buffer: [UInt8] = []
        // Interpreter processes whose arguments could not be read. A process in the middle of starting
        // has none for a moment, so each is read again after the rest of the table, up to `attempts` times.
        var pending: [(pid: Int32, short: String?, executable: String?)] = []
        for pid in pids where pid > 0 {
            let short = ProcessTable.shortName(of: pid)
            let executable = ProcessTable.executablePath(of: pid)
            if matches(name: name, shortName: short, executable: executable, argv: nil) { return .running }
            switch ProcessTable.arguments(of: pid, buffer: &buffer) {
            case .read(_, let argv):
                if matches(name: name, shortName: short, executable: executable, argv: argv) { return .running }
            case .gone:
                continue
            case .unreadable:
                if isInterpreter(shortName: short, executable: executable),
                    ProcessTable.belongsToCurrentUser(pid) != false
                {
                    pending.append((pid, short, executable))
                }
            }
        }
        for _ in 0..<attempts where !pending.isEmpty {
            var again: [(pid: Int32, short: String?, executable: String?)] = []
            for entry in pending {
                switch ProcessTable.arguments(of: entry.pid, buffer: &buffer) {
                case .read(_, let argv):
                    if matches(name: name, shortName: entry.short, executable: entry.executable, argv: argv) {
                        return .running
                    }
                case .gone:
                    continue
                case .unreadable:
                    again.append(entry)
                }
            }
            pending = again
        }
        return pending.isEmpty ? .notRunning : .unknown
    }

    /// How many times an interpreter process whose arguments could not be read is read again.
    static let attempts = 3

    /// Whether a running app has a bundle identifier that starts with `prefix` (compared without
    /// regard to case). The app is found from each process's executable path: every enclosing `.app`
    /// folder is read for `CFBundleIdentifier`.
    ///
    /// `.unknown` when the process list cannot be read, or when the bundle of one of the current
    /// user's processes exists but cannot be read.
    static func state(ofBundleIDPrefix prefix: String) -> OwnerState {
        let wanted = prefix.lowercased()
        guard !wanted.isEmpty, let pids = ProcessTable.allPIDs() else { return .unknown }
        var seen: [String: BundleRead] = [:]
        var unsure = false
        for pid in pids where pid > 0 {
            guard let executable = ProcessTable.executablePath(of: pid) else { continue }
            for bundle in appBundlePaths(in: executable) {
                let read = seen[bundle] ?? readBundleID(atAppPath: bundle)
                seen[bundle] = read
                switch read {
                case .identifier(let id):
                    if id.lowercased().hasPrefix(wanted) { return .running }
                case .noBundle:
                    continue
                case .unreadable:
                    if ProcessTable.belongsToCurrentUser(pid) != false { unsure = true }
                }
            }
        }
        return unsure ? .unknown : .notRunning
    }

    // MARK: Helpers

    /// Every enclosing `.app` folder in a path, outermost first.
    static func appBundlePaths(in executable: String) -> [String] {
        let parts = executable.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var result: [String] = []
        for (index, part) in parts.enumerated().dropLast()
        where (part as NSString).pathExtension.lowercased() == "app" {
            result.append("/" + parts[0...index].joined(separator: "/"))
        }
        return result
    }

    /// What reading an app's `Contents/Info.plist` gave.
    enum BundleRead: Equatable {
        case identifier(String)
        /// There is no `Info.plist` (not a real bundle, or the app was moved or removed).
        case noBundle
        /// The file exists but could not be read or parsed.
        case unreadable
    }

    /// Reads `CFBundleIdentifier` of the app at `path`.
    static func readBundleID(atAppPath path: String) -> BundleRead {
        let plist = URL(filePath: path, directoryHint: .isDirectory)
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Info.plist", directoryHint: .notDirectory)
        let data: Data
        do {
            data = try Data(contentsOf: plist)
        } catch let error as NSError {
            let missing = error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
            return missing ? .noBundle : .unreadable
        }
        guard data.count <= 4 << 20,
            let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dictionary = object as? [String: Any]
        else { return .unreadable }
        guard let id = dictionary["CFBundleIdentifier"] as? String, !id.isEmpty else { return .noBundle }
        return .identifier(id)
    }

    private static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func withoutScriptExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return scriptExtensions.contains(ext) ? (name as NSString).deletingPathExtension : name
    }
}
