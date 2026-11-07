import Foundation
import Testing
@testable import CleanerCore

/// `{a,b}` alternatives in `GlobPattern`.
struct GlobBraceTests {
    private func matches(_ pattern: String, _ path: String) -> Bool {
        GlobPattern(pattern).matches(path.split(separator: "/").map { PathText.fold(String($0)) })
    }

    @Test func expandsEveryOption() {
        #expect(GlobPattern.expandBraces("a/{b,c}/d") == ["a/b/d", "a/c/d"])
        #expect(GlobPattern.expandBraces("{x,y}/{1,2}") == ["x/1", "x/2", "y/1", "y/2"])
        #expect(GlobPattern.expandBraces("*.{download,crdownload,part}")
            == ["*.download", "*.crdownload", "*.part"])
    }

    @Test func anOptionMayHoldSeveralComponents() {
        #expect(matches("*/**/{a,b/c}", "proj/a"))
        #expect(matches("*/**/{a,b/c}", "proj/x/b/c"))
        #expect(!matches("*/**/{a,b/c}", "proj/b"))
    }

    @Test func emptyOptionIsAllowed() {
        #expect(GlobPattern.expandBraces("a{,b}") == ["a", "ab"])
    }

    @Test("A brace that is not a group stays an ordinary character", arguments: [
        "a{b", "a}b", "a{b}", "{", "}", "a}{b,c",
    ])
    func notAGroup(text: String) {
        #expect(GlobPattern.expandBraces(text) == [text])
    }

    @Test func tooManyAlternativesKeepThePatternAsWritten() {
        let many = (0..<5).map { _ in "{a,b,c,d}" }.joined(separator: "/")
        #expect(4 * 4 * 4 * 4 * 4 > GlobPattern.maxAlternatives)
        #expect(GlobPattern.expandBraces(many) == [many])
        // Kept as written, it matches nothing that exists.
        #expect(!matches(many, "a/a/a/a/a"))
    }

    @Test func patternsWithoutBracesAreUnchanged() {
        #expect(GlobPattern.expandBraces("~/Library/Caches/**") == ["~/Library/Caches/**"])
        #expect(matches("Install macOS*.app", "install macos sequoia.app"))
    }
}
