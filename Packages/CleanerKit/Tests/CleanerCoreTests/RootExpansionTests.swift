import Foundation
import Testing
@testable import CleanerCore

struct RootExpansionTests {
    private let env = TestEnv.environment()

    @Test func homeRootIsConcrete() throws {
        let root = try #require(RootExpansion.expand(RootSpec(base: .home, components: ["Library", "Caches"]), in: env))
        #expect(root.isConcrete)
        #expect(root.url?.path() == "/Users/tester/Library/Caches/")
        #expect(root.pattern.isEmpty)
    }

    @Test func absoluteRoot() throws {
        let root = try #require(RootExpansion.expand(RootSpec(base: .absolute, components: ["Library", "Logs"]), in: env))
        #expect(root.url?.path() == "/Library/Logs/")
    }

    @Test func spacesAndDotsStayLiteral() throws {
        let spec = RootSpec(base: .home, components: ["Library", "Application Support", ".hidden"])
        let root = try #require(RootExpansion.expand(spec, in: env))
        #expect(root.url?.path(percentEncoded: false) == "/Users/tester/Library/Application Support/.hidden/")
    }

    @Test func wildcardIsLeftForTheScanner() throws {
        let spec = RootSpec(base: .home, components: ["Library", "Containers", "*", "Data", "Library", "Caches"])
        let root = try #require(RootExpansion.expand(spec, in: env))
        #expect(!root.isConcrete)
        #expect(root.url == nil)
        #expect(root.base.path() == "/Users/tester/Library/Containers/")
        #expect(root.pattern == ["*", "Data", "Library", "Caches"])
    }

    @Test func partialWildcardCountsAsPattern() throws {
        let spec = RootSpec(base: .home, components: ["Library", "Caches", "Google", "AndroidStudio*"])
        let root = try #require(RootExpansion.expand(spec, in: env))
        #expect(root.base.path() == "/Users/tester/Library/Caches/Google/")
        #expect(root.pattern == ["AndroidStudio*"])
    }

    @Test func darwinDirectories() throws {
        let cache = try #require(RootExpansion.expand(RootSpec(base: .darwinUserCache, components: []), in: env))
        #expect(cache.url?.path() == "/private/var/folders/ab/cdef/C/")
        let temp = try #require(RootExpansion.expand(RootSpec(base: .darwinUserTemp, components: ["x"]), in: env))
        #expect(temp.url?.path() == "/private/var/folders/ab/cdef/T/x/")
    }

    @Test func unknownBaseGivesNoRoot() {
        let bare = Environment(home: TestEnv.home, now: TestEnv.now)
        #expect(RootExpansion.expand(RootSpec(base: .darwinUserCache, components: []), in: bare) == nil)
        #expect(RootExpansion.expand(RootSpec(base: .darwinUserTemp, components: []), in: bare) == nil)
    }

    @Test("Unsafe components give no root", arguments: ["", ".", "..", "a/b", "a\0b"])
    func unsafeComponents(component: String) {
        #expect(RootExpansion.expand(RootSpec(base: .home, components: ["Library", component]), in: env) == nil)
        #expect(RootExpansion.expand(RootSpec(base: .home, components: ["*", component]), in: env) == nil)
    }

    @Test func relativeHomeGivesNoRoot() throws {
        let bad = Environment(home: try #require(URL(string: "relative")), now: TestEnv.now)
        #expect(RootExpansion.expand(RootSpec(base: .home, components: ["Library"]), in: bad) == nil)
    }
}
