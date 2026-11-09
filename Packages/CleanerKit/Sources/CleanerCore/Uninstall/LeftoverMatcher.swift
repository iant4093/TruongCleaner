import Foundation

/// Decides which entries of the searched folders belong to one app (`docs/UNINSTALLER.md` §3).
///
/// Pure: it reads no file system. The caller lists the folders, reads container metadata and launch
/// job plists, and passes the result in. Every comparison is on whole names, ignoring case. There is
/// no substring or prefix matching of names, except "bundle ID + `.` + suffix".
///
/// When in doubt an entry is not offered, or it is offered as `.review` (not selected).
public enum LeftoverMatcher {
    /// Shortest app name that may match a folder by name alone.
    public static let minimumNameLength = 4

    /// Finds the entries that belong to `app`.
    ///
    /// - Parameters:
    ///   - app: The app being removed.
    ///   - inventory: Every installed app, including `app` itself. An incomplete inventory turns
    ///     off every match that rests on names or team IDs.
    ///   - listings: The direct children of each searched folder. A folder that is missing from the
    ///     dictionary was not read and yields nothing.
    ///   - childNames: The names inside one candidate folder, or nil when they could not be listed.
    ///     Asked only for candidates that are folders in `~/Library`. A folder that holds another
    ///     installed app's bundle ID in a child name is dropped.
    /// - Returns: Candidates in folder order, then by name. `/Library` candidates are `.info`.
    public static func match(
        app: AppFacts,
        inventory: InstalledApps,
        listings: [LeftoverPlace: [LeftoverEntry]],
        childNames: (LeftoverPlace, String) -> [String]?
    ) -> LeftoverMatches {
        guard let rawID = app.bundleID, !rawID.isEmpty else {
            return LeftoverMatches(candidates: [], notice: "This app has no bundle ID, so no files were matched.")
        }
        let others = inventory.apps.filter { $0.id != app.id }
        let subject = Subject(app: app, id: BundleIDText.fold(rawID), rawID: rawID, others: others)
        if others.contains(where: { $0.bundleID.map(BundleIDText.fold) == subject.id }) {
            return LeftoverMatches(
                candidates: [],
                notice: "Another copy of this app is installed, so its files were left alone.")
        }

        var candidates: [LeftoverCandidate] = []
        for place in LeftoverPlace.all {
            let entries = (listings[place] ?? []).sorted { $0.name < $1.name }
            for entry in entries {
                guard var candidate = subject.candidate(for: entry, in: place, inventoryComplete: inventory.isComplete)
                else { continue }
                if place.scope == .user, entry.isDirectory,
                    !subject.keepsAfterChildCheck(candidate, children: childNames(place, entry.name))
                {
                    continue
                }
                if place.scope == .system { candidate.tier = .info }
                candidates.append(candidate)
            }
        }
        let notice = inventory.isComplete
            ? nil
            : "The list of installed apps could not be read in full, so files matched only by name were left out."
        return LeftoverMatches(candidates: candidates, notice: notice)
    }

    /// Whether a launch job's program lies strictly inside the app bundle. Relative paths, `.` and
    /// `..` never count.
    static func isInside(program: String, app: URL) -> Bool {
        guard program.hasPrefix("/") else { return false }
        let programParts = program.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !programParts.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        let appParts = app.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let wanted = withoutDataVolume(appParts).map(BundleIDText.fold)
        let actual = withoutDataVolume(programParts).map(BundleIDText.fold)
        return actual.count > wanted.count && actual.starts(with: wanted)
    }

    /// `System/Volumes/Data/...` is the same place as `...` (firmlinks).
    private static func withoutDataVolume(_ parts: [String]) -> [String] {
        parts.count > 3 && parts[0] == "System" && parts[1] == "Volumes" && parts[2] == "Data"
            ? Array(parts.dropFirst(3)) : parts
    }

    // MARK: - One app

    /// The app and the facts about the other installed apps that every decision needs.
    private struct Subject {
        let app: AppFacts
        /// Folded bundle ID.
        let id: String
        let rawID: String
        let others: [AppFacts]
        let allowsSuffix: Bool
        /// Folded names of the app that may match a folder name, with the original spelling.
        let names: [(folded: String, shown: String)]
        let team: String?
        let otherIDs: [String]

        init(app: AppFacts, id: String, rawID: String, others: [AppFacts]) {
            self.app = app
            self.id = id
            self.rawID = rawID
            self.others = others
            self.allowsSuffix = BundleIDText.allowsSuffix(id)
            var seen = Set<String>()
            self.names = [app.name, app.displayName, app.executableName].compactMap { $0 }.compactMap { shown in
                let folded = BundleIDText.fold(shown)
                guard folded.count >= LeftoverMatcher.minimumNameLength, seen.insert(folded).inserted else {
                    return nil
                }
                return (folded, shown)
            }
            self.team = app.teamID.flatMap { $0.isEmpty ? nil : BundleIDText.fold($0) }
            self.otherIDs = others.compactMap { $0.bundleID }.map(BundleIDText.fold).filter { !$0.isEmpty }
        }

        /// The strongest evidence for an entry, or nil when it does not belong to the app.
        func candidate(for entry: LeftoverEntry, in place: LeftoverPlace, inventoryComplete: Bool)
            -> LeftoverCandidate?
        {
            let name = BundleIDText.fold(entry.name)
            // A `.app` is never a leftover: the uninstall rule may remove a whole `.app`, and only the
            // app itself should be one.
            guard !name.isEmpty, !name.hasSuffix(".app") else { return nil }

            if place.folder.holdsLaunchJobs {
                return launchJobCandidate(entry, place: place)
            }
            if name == id {
                return make(entry, place, .safe, .exactBundleID(rawID), identifier: name)
            }
            if allowsSuffix, name.hasPrefix(id + ".") {
                return make(entry, place, .safe, .bundleIDPrefix(rawID), identifier: name)
            }
            if place.folder == .containers, let metadata = entry.metadataIdentifier {
                let folded = BundleIDText.fold(metadata)
                if folded == id || (allowsSuffix && folded.hasPrefix(id + ".")) {
                    return make(entry, place, .safe, .containerMetadata(rawID), identifier: folded)
                }
            }
            if place.folder == .groupContainers, let group = groupCandidate(entry, place, name, inventoryComplete) {
                return group
            }
            // Name only. Needs a trustworthy inventory to prove no other app shares the name.
            if inventoryComplete, let own = names.first(where: { $0.folded == name }), !isUsedByAnotherApp(name) {
                return make(entry, place, .review, .appName(own.shown), identifier: nil)
            }
            return nil
        }

        private func launchJobCandidate(_ entry: LeftoverEntry, place: LeftoverPlace) -> LeftoverCandidate? {
            guard let job = entry.launchJob, let label = job.label else { return nil }
            let folded = BundleIDText.fold(label)
            guard folded == id || (allowsSuffix && folded.hasPrefix(id + ".")) else { return nil }
            if belongsToLongerApp(folded) { return nil }
            if place.scope == .user {
                // Label and program: both must point at this app.
                guard !job.programs.isEmpty, job.programs.allSatisfy({ LeftoverMatcher.isInside(program: $0, app: app.url) })
                else { return nil }
                return LeftoverCandidate(place: place, name: entry.name, tier: .safe, evidence: .launchJob(label: label))
            }
            return LeftoverCandidate(place: place, name: entry.name, tier: .info, evidence: .launchJobLabel(label: label))
        }

        private func groupCandidate(
            _ entry: LeftoverEntry, _ place: LeftoverPlace, _ name: String, _ inventoryComplete: Bool
        ) -> LeftoverCandidate? {
            let group = "group." + id
            if name == group || (allowsSuffix && name.hasPrefix(group + ".")) {
                return make(entry, place, .review, .groupContainerBundleID(rawID), identifier: String(name.dropFirst(6)))
            }
            // `<teamID>.<something>` is shared by every app of that developer. It is offered only when no
            // other installed app has the same team ID, and only with a complete inventory.
            guard let team, name.hasPrefix(team + "."), name.count > team.count + 1, inventoryComplete,
                !others.contains(where: { $0.teamID.map(BundleIDText.fold) == team })
            else { return nil }
            let rest = String(name.dropFirst(team.count + 1))
            return make(entry, place, .review, .groupContainerTeamID(app.teamID ?? team), identifier: rest)
        }

        private func make(
            _ entry: LeftoverEntry, _ place: LeftoverPlace, _ tier: Tier, _ evidence: LeftoverEvidence,
            identifier: String?
        ) -> LeftoverCandidate? {
            if let identifier, belongsToLongerApp(identifier) { return nil }
            return LeftoverCandidate(place: place, name: entry.name, tier: tier, evidence: evidence)
        }

        /// Whether another installed app has an ID that extends this app's ID and covers the identifier.
        /// Chrome's `com.google.Chrome` is a prefix of Canary's `com.google.Chrome.canary`: Canary's
        /// files belong to Canary, not to Chrome.
        private func belongsToLongerApp(_ identifier: String) -> Bool {
            otherIDs.contains { other in
                other.count > id.count && other.hasPrefix(id + ".")
                    && (identifier == other || identifier.hasPrefix(other + "."))
            }
        }

        /// Whether another installed app is called `name` (by name, display name, executable, or the
        /// last part of its bundle ID).
        private func isUsedByAnotherApp(_ name: String) -> Bool {
            others.contains { other in
                let own = [other.name, other.displayName, other.executableName].compactMap { $0 }.map(BundleIDText.fold)
                if own.contains(name) { return true }
                if let identifier = other.bundleID {
                    return BundleIDText.lastComponent(BundleIDText.fold(identifier)) == name
                }
                return false
            }
        }

        /// Rule 3: a folder with another installed app's bundle ID in a child's name is not this app's.
        /// Unlisted children keep a `.safe` candidate (its evidence is a bundle ID) and drop the others.
        func keepsAfterChildCheck(_ candidate: LeftoverCandidate, children: [String]?) -> Bool {
            guard let children else { return candidate.tier == .safe }
            for child in children {
                let folded = BundleIDText.fold(child)
                // This app's own ID can sit inside a child name (`<id>.helper`) and, being a prefix of
                // another app's ID, look like it. Take it out before looking for IDs that do not extend it.
                let scrubbed = folded.replacingOccurrences(of: id, with: "")
                for other in otherIDs {
                    let extendsThisApp = other.count > id.count && other.hasPrefix(id + ".")
                    if (extendsThisApp ? folded : scrubbed).contains(other) { return false }
                }
            }
            return true
        }
    }
}
