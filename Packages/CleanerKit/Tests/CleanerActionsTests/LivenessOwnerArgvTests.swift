import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Testing

@testable import CleanerActions

/// Pre-v1.0 safety review, findings 4, 11 and 14: owners found by argument vector and by bundle ID
/// prefix, liveness coverage over the user's own processes, and the owner-command preflights.
struct LivenessOwnerArgvTests {
    // MARK: Pure matching

    @Test(arguments: [
        // (name, short name, executable, argv, expected)
        ("npm", "node", "/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/npm", "install"], true),
        ("npm", "node", "/opt/homebrew/bin/node", ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js"], false),
        ("yarn", "node", "/usr/local/bin/node", ["node", "/usr/local/bin/yarn.js", "add", "x"], true),
        ("pnpm", "node", "/usr/local/bin/node", ["node", "/usr/local/lib/pnpm/bin/pnpm.cjs", "install"], true),
        ("pod", "ruby", "/usr/bin/ruby", ["ruby", "/opt/homebrew/bin/pod", "install"], true),
        ("brew", "bash", "/bin/bash", ["/bin/bash", "/opt/homebrew/Library/Homebrew/brew.sh", "cleanup"], true),
        ("brew", "ruby", "/usr/bin/ruby", ["ruby", "/opt/homebrew/Library/Homebrew/brew.rb"], true),
        ("npm", "node", "/usr/local/bin/node", ["node", "server.js"], false),
        ("npm", "vim", "/usr/bin/vim", ["vim", "npm.txt"], false),
        ("swift", "swift-build", "/usr/bin/swift-build", ["swift-build", "--package-path", "x"], true),
        ("swift", "swift-frontend", "/usr/bin/swift-frontend", ["swift-frontend", "-frontend"], true),
        ("swift", "swift", "/usr/bin/swift", ["swift", "build"], true),
        ("swift", "swiftlint", "/opt/homebrew/bin/swiftlint", ["swiftlint"], false),
        ("gradle", "java", "/usr/bin/java", [
            "java", "-cp", "gradle-launcher.jar", "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "8.5",
        ], true),
        ("gradle", "java", "/usr/bin/java", ["java", "-jar", "app.jar"], false),
        ("gradle", "gradle", "/opt/homebrew/bin/gradle", ["gradle"], true),
        ("cargo", "cargo", "/Users/x/.cargo/bin/cargo", ["cargo", "build"], true),
        ("uv", "uvicorn", "/usr/bin/python3", ["python3", "-m", "uvicorn"], false),
    ] as [(String, String, String, [String], Bool)])
    func matcher_decidesFromNameAndArguments(
        name: String, shortName: String, executable: String, argv: [String], expected: Bool
    ) {
        #expect(
            ProcessOwnerMatcher.matches(name: name, shortName: shortName, executable: executable, argv: argv)
                == expected)
    }

    @Test func matcher_withoutArgumentsOnlyTheNamesCount() {
        #expect(!ProcessOwnerMatcher.matches(name: "npm", shortName: "node", executable: "/usr/bin/node", argv: nil))
        #expect(ProcessOwnerMatcher.matches(name: "node", shortName: "node", executable: "/usr/bin/node", argv: nil))
        #expect(!ProcessOwnerMatcher.matches(name: "", shortName: "", executable: "", argv: []))
    }

    @Test func matcher_interpretersAreTheProcessesWhoseArgumentsMatter() {
        for name in ["node", "ruby", "java", "bash", "sh", "python3", "python3.12", "javac"] {
            #expect(ProcessOwnerMatcher.isInterpreter(shortName: name, executable: nil), "\(name)")
        }
        #expect(ProcessOwnerMatcher.isInterpreter(shortName: nil, executable: "/opt/homebrew/bin/node"))
        for name in ["Finder", "launchd", "sleep"] {
            #expect(!ProcessOwnerMatcher.isInterpreter(shortName: name, executable: nil), "\(name)")
        }
    }

    // MARK: Reading arguments

    @Test func arguments_replyIsParsedIntoPathAndArgv() {
        var reply = [UInt8](withUnsafeBytes(of: Int32(3)) { Array($0) })
        reply += Array("/usr/bin/node".utf8) + [0, 0, 0]
        reply += Array("node".utf8) + [0] + Array("/opt/bin/npm".utf8) + [0] + Array("install".utf8) + [0]
        reply += Array("HOME=/x".utf8) + [0]
        #expect(ProcessTable.parse(reply) == .read(executable: "/usr/bin/node", argv: ["node", "/opt/bin/npm", "install"]))
    }

    @Test(arguments: [
        [UInt8](),
        [1, 0, 0, 0],
        [200, 15, 0, 0, 0x2F, 0],  // argc 4040 with no arguments behind it
        [2, 0, 0, 0, 0x2F, 0, 0, 0x61, 0],  // argc 2, one argument present
        [0xFF, 0xFF, 0xFF, 0xFF, 0x2F, 0],  // negative argc
    ])
    func arguments_aBrokenReplyIsUnreadableNotEmpty(reply: [UInt8]) {
        #expect(ProcessTable.parse(reply) == .unreadable)
    }

    @Test func arguments_ownProcessCanBeRead() {
        var buffer: [UInt8] = []
        guard case .read(let executable, let argv) = ProcessTable.arguments(of: getpid(), buffer: &buffer) else {
            Issue.record("Could not read the arguments of the test process")
            return
        }
        #expect(!executable.isEmpty)
        #expect(argv.count == CommandLine.arguments.count)
        #expect(argv.first == CommandLine.arguments.first)
    }

    // MARK: Real processes

    /// A throwaway child process. Ended by `kill()`.
    private final class Child: Sendable {
        let process = Process()

        init(_ executable: String, _ arguments: [String]) throws {
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        func kill() {
            if process.isRunning { process.terminate() }
        }
    }

    /// Polls `check` for up to five seconds, because a new process needs a moment to appear.
    private func eventually(_ check: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await check()
    }

    /// A script that idles until it is killed. Returns its path.
    private func script(_ tree: FixtureTree, named name: String) throws -> URL {
        let url = try tree.addFile("bin/\(name)")
        try Data("#!/bin/sh\nwhile :; do sleep 1; done\n".utf8).write(to: url)
        return url
    }

    @Test(arguments: ["", ".cjs", ".js", ".sh"])
    func running_aScriptRunBySHIsFoundByTheScriptName(ext: String) async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = "tctool-\(UUID().uuidString.prefix(8))"
        let child = try Child("/bin/sh", [try script(tree, named: tool + ext).path(percentEncoded: false)])
        defer { child.kill() }
        let provider = ProcessNameOwnerProvider()
        let item = URL(filePath: "/tmp/x")

        // The process is `sh`; only its arguments give the tool away.
        #expect(await eventually { await provider.state(of: .processName(tool), for: item) == .running })
        let negative = await provider.state(of: .processName(tool + "x"), for: item)
        #expect(negative == .notRunning, "state \(negative)")
    }

    @Test func running_theToolIsNotRunningOnceTheScriptEnds() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let tool = "tctool-\(UUID().uuidString.prefix(8))"
        let child = try Child("/bin/sh", [try script(tree, named: tool).path(percentEncoded: false)])
        let provider = ProcessNameOwnerProvider()
        let item = URL(filePath: "/tmp/x")
        #expect(await eventually { await provider.state(of: .processName(tool), for: item) == .running })
        child.kill()
        #expect(await eventually { await provider.state(of: .processName(tool), for: item) == .notRunning })
    }

    @Test func running_theGradleDaemonIsFoundByItsMainClass() async throws {
        let child = try Child(
            "/bin/sh",
            ["-c", "while :; do sleep 1; done", "org.gradle.launcher.daemon.bootstrap.GradleDaemon"])
        defer { child.kill() }
        let provider = ProcessNameOwnerProvider()
        #expect(await eventually {
            await provider.state(of: .processName("gradle"), for: URL(filePath: "/tmp/x")) == .running
        })
    }

    /// A fixture app whose executable is a copy of `/bin/sleep`, with a bundle ID in its `Info.plist`.
    /// Returns nil when the copy cannot be run (the test then has nothing to check).
    private func startFixtureApp(_ tree: FixtureTree, bundleID: String) throws -> Child? {
        let executable = try tree.addDirectory("Adobe Premiere Pro 2025.app/Contents/MacOS")
            .appending(path: "Adobe Premiere Pro 2025")
        try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: executable)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0)
        try plist.write(to: tree.url(for: "Adobe Premiere Pro 2025.app/Contents/Info.plist"))
        guard let child = try? Child(executable.path(percentEncoded: false), ["30"]) else { return nil }
        return child
    }

    @Test func running_aBundleIDPrefixFindsAnAppWhoseNameCarriesTheYear() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let unique = "com.tcfixture\(UUID().uuidString.prefix(8).lowercased())"
        guard let child = try startFixtureApp(tree, bundleID: "\(unique).PremierePro.25") else {
            Issue.record("The fixture app could not be started; the prefix match is untested here")
            return
        }
        defer { child.kill() }
        let provider = ProcessNameOwnerProvider()
        let item = URL(filePath: "/tmp/x")

        #expect(await eventually {
            await provider.state(of: .bundleID("\(unique).PremierePro.*"), for: item) == .running
        })
        // Case is ignored, like the app layer does for whole bundle IDs.
        #expect(await provider.state(of: .bundleID("\(unique.uppercased()).premierepro.*"), for: item) == .running)
        #expect(await provider.state(of: .bundleID("\(unique).AfterEffects*"), for: item) == .notRunning)
        // A whole bundle ID is still the app layer's to answer.
        #expect(await provider.state(of: .bundleID("\(unique).PremierePro.25"), for: item) == .unknown)
    }

    @Test func running_theGateAnswersABundleIDPrefixItselfEvenWhenTheAppProviderSaysNotRunning() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let unique = "com.tcfixture\(UUID().uuidString.prefix(8).lowercased())"
        guard let child = try startFixtureApp(tree, bundleID: "\(unique).PremierePro.25") else {
            Issue.record("The fixture app could not be started; the gate's prefix match is untested here")
            return
        }
        defer { child.kill() }
        try await withHarness { h in
            let file = try h.tree.addFile("home/Library/Caches/media.bin", size: 10)
            let rule = h.rule(guards: Guards(owners: [.bundleID("\(unique).PremierePro.*")]))
            // The app layer compares whole IDs and would answer "not running" for a pattern.
            let context = h.context(apps: FakeApps(fallback: .notRunning))
            let verdict = try await eventuallyDenied(h, file, rule, context)
            #expect(verdict == .deny(.ownerOpen("\(unique).PremierePro.*")))

            let other = h.rule(guards: Guards(owners: [.bundleID("\(unique).AfterEffects*")]))
            #expect(try await h.verdict(for: file, rule: other, context: context).isAllowed)
        }
    }

    private func eventuallyDenied(
        _ h: GateHarness, _ file: URL, _ rule: Rule, _ context: GateContext
    ) async throws -> Verdict {
        var verdict = try await h.verdict(for: file, rule: rule, context: context)
        let deadline = Date().addingTimeInterval(5)
        while verdict.isAllowed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            verdict = try await h.verdict(for: file, rule: rule, context: context)
        }
        return verdict
    }

    @Test func appBundlePaths_listEveryEnclosingApp() {
        let paths = ProcessOwnerMatcher.appBundlePaths(
            in: "/Applications/Adobe Premiere Pro 2025/Adobe Premiere Pro 2025.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")
        #expect(paths == [
            "/Applications/Adobe Premiere Pro 2025/Adobe Premiere Pro 2025.app",
            "/Applications/Adobe Premiere Pro 2025/Adobe Premiere Pro 2025.app/Contents/Frameworks/Helper.app",
        ])
        #expect(ProcessOwnerMatcher.appBundlePaths(in: "/usr/bin/sleep").isEmpty)
        // The executable itself is not a bundle even when its name ends in `.app`.
        #expect(ProcessOwnerMatcher.appBundlePaths(in: "/tmp/tool.app").isEmpty)
    }

    // MARK: Finding 11: coverage over the user's own processes

    @Test func coverage_processesOfOtherUsersDoNotCountAgainstTheSnapshot() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("a.bin", size: 1)
        let rootProcesses = (ProcessTable.allPIDs() ?? []).filter { $0 > 0 && ProcessTable.ownerUID(of: $0) == 0 }
        // Some sandboxes hide the owner of other users' processes. Then no process can be told apart as
        // "not the user's", and there is nothing to compare.
        guard rootProcesses.count >= 4 else { return }
        let me = getpid()
        // One readable process of the user and many root processes. Counted over all processes, that
        // is 1 of 5 or fewer and the snapshot fails. Counted over the user's own, it is 1 of 1.
        let pids = [me] + rootProcesses.prefix(8)
        let snapshot = ProcessInspector.capture(excluding: [], listProcesses: { Array(pids) })
        let answer = await snapshot.hasOpenFiles(under: file)
        #expect(answer != nil)
    }

    @Test func coverage_aSnapshotWithOnlyRootProcessesStillFails() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = try tree.addFile("a.bin", size: 1)
        let rootProcesses = (ProcessTable.allPIDs() ?? []).filter { $0 > 0 && ProcessTable.ownerUID(of: $0) == 0 }
        let pids = Array(rootProcesses.prefix(8))
        let snapshot = ProcessInspector.capture(excluding: [], listProcesses: { pids })
        #expect(await snapshot.hasOpenFiles(under: file) == nil)
    }

    @Test func coverage_theCurrentUserIsRecognisedFromTheProcessTable() {
        #expect(ProcessTable.belongsToCurrentUser(getpid()) == true)
        if ProcessTable.ownerUID(of: 1) != nil {
            #expect(ProcessTable.belongsToCurrentUser(1) == false)
        }
    }

    // MARK: Finding 14: owner commands

    @Test func brewAndPnpmPreflightsUseTheArgumentMatcher() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        // Homebrew runs as `bash .../brew.sh`; pnpm as `node .../pnpm.cjs`. Here `sh` plays both, and
        // unique names stand for the tools so that parallel tests cannot disturb each other.
        let brew = "tcbrew-\(UUID().uuidString.prefix(8))"
        let child = try Child("/bin/sh", [try script(tree, named: brew + ".sh").path(percentEncoded: false)])
        defer { child.kill() }
        #expect(await eventually { ProcessNameOwnerProvider.isProcessRunning(named: brew) == .running })
        #expect(ProcessNameOwnerProvider.isProcessRunning(named: brew + "-other") == .notRunning)
    }

    @Test func brewCommandMatchesTheCatalogPathsAndTimeout() throws {
        let brew = try #require(OwnerCommands.all[.brewCleanup])
        #expect(brew.candidates == ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
        #expect(brew.timeout == .seconds(300))
        #expect(brew.arguments == ["cleanup", "--prune=30"])
        #expect(brew.preflight == .processNotRunning("brew"))
        #expect(OwnerCommands.all[.pnpmStorePrune]?.preflight == .processNotRunning("pnpm"))
    }
}
