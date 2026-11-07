import Foundation
import Testing
@testable import CleanerCore

/// `RootSpec.Base.userChosen`: project folders the user picked.
struct ProjectFolderExpansionTests {
    private let spec = RootSpec(base: .userChosen, components: [])

    private func env(_ folders: [String]) -> Environment {
        TestEnv.environment(projectFolders: folders.map { TestEnv.url($0) })
    }

    @Test func noChosenFolderMeansNoRoot() {
        #expect(RootExpansion.starts(of: spec, in: env([])).isEmpty)
        #expect(RootExpansion.expand(spec, in: env([])) == nil)
    }

    @Test func eachChosenFolderIsARoot() throws {
        let starts = RootExpansion.starts(of: spec, in: env(["~/Code", "/Volumes/Work/src"]))
        #expect(starts.map { $0.path(percentEncoded: false) } == ["/Users/tester/Code", "/Volumes/Work/src"])
        let root = try #require(RootExpansion.expand(spec, from: starts[1]))
        #expect(root.url?.path(percentEncoded: false) == "/Volumes/Work/src")
        #expect(root.isConcrete)
    }

    @Test func componentsAreRelativeToEachChosenFolder() throws {
        let sub = RootSpec(base: .userChosen, components: ["apps", "*"])
        let start = try #require(RootExpansion.starts(of: sub, in: env(["~/Code"])).first)
        let root = try #require(RootExpansion.expand(sub, from: start))
        #expect(root.base.path(percentEncoded: false) == "/Users/tester/Code/apps/")
        #expect(root.pattern == ["*"])
    }

    @Test func expandInReturnsNilBecauseSeveralFoldersAreMeant() {
        #expect(RootExpansion.expand(spec, in: env(["~/Code"])) == nil)
    }

    @Test("Folders we never clean from the top, or the protected list covers, are ignored", arguments: [
        "/", "~", "~/Library", "/Library", "/Applications", "/Users", "/System/Library", "/usr/local",
        "~/Library/CloudStorage", "~/Library/CloudStorage/Dropbox", "~/Library/Mobile Documents",
        "~/Library/Mail", "~/.claude/projects", "~/Library/Keychains",
    ])
    func unsafeFolders(path: String) {
        #expect(RootExpansion.starts(of: spec, in: env([path])).isEmpty, "\(path)")
    }

    @Test func relativeAndDuplicateFoldersAreIgnored() throws {
        let notAFileURL = try #require(URL(string: "relative/Code"))
        let relative = Environment(home: TestEnv.home, now: TestEnv.now, projectFolders: [notAFileURL])
        #expect(RootExpansion.starts(of: spec, in: relative).isEmpty)
        let starts = RootExpansion.starts(of: spec, in: env(["~/Code", "~/code", "~/Code/", "~/Code/../Code"]))
        #expect(starts.count == 1)
    }

    @Test func otherBasesIgnoreProjectFolders() throws {
        let home = RootSpec(base: .home, components: ["Library"])
        let starts = RootExpansion.starts(of: home, in: env(["~/Code"]))
        #expect(starts == [TestEnv.home])
    }
}
