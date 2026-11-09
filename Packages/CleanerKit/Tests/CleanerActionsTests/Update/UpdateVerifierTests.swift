import CleanerTestSupport
import Darwin
import Foundation
import Testing

@testable import CleanerActions

struct UpdateVerifierTests {
    private let verifier = UpdateVerifier()

    @Test func verify_acceptsAnIntactAdHocSignedNewerBuild() async throws {
        try await withUpdateTree { tree in
            let app = try FixtureApp.make(in: tree, at: "new/TruongCleaner.app")
            let verified = try await verifier.verify(app, against: .fixture)
            #expect(verified.bundleVersion == 2000)
            #expect(verified.app == app)
        }
    }

    @Test func verify_refusesAnotherBundleIdentifier() async throws {
        try await withUpdateTree { tree in
            var spec = FixtureApp.Spec()
            spec.bundleID = "com.example.NotUs"
            let app = try FixtureApp.make(in: tree, at: "new/TruongCleaner.app", spec)
            await #expect(throws: UpdateError.wrongBundleIdentifier) {
                try await verifier.verify(app, against: .fixture)
            }
        }
    }

    @Test(arguments: [1000, 999, 1])
    func verify_refusesABuildThatIsNotNewer(_ build: Int) async throws {
        try await withUpdateTree { tree in
            var spec = FixtureApp.Spec()
            spec.build = build
            let app = try FixtureApp.make(in: tree, at: "new/TruongCleaner.app", spec)
            await #expect(throws: UpdateError.notNewer) {
                try await verifier.verify(app, against: .fixture)
            }
        }
    }

    @Test func verify_refusesAnUnreadableBuildNumber() async throws {
        try await withUpdateTree { tree in
            let app = try FixtureApp.stub(in: tree, at: "new/TruongCleaner.app")
            let plist = app.appending(path: "Contents/Info.plist")
            var dictionary = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
            dictionary["CFBundleVersion"] = "twenty"
            try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: plist)
            await #expect(throws: UpdateError.unreadableBundle) {
                try await verifier.verify(app, against: .fixture)
            }
        }
    }

    @Test func verify_refusesAnUpdateThatNeedsANewerMacOS() async throws {
        try await withUpdateTree { tree in
            var spec = FixtureApp.Spec()
            spec.minimumSystem = "27.1"
            let app = try FixtureApp.make(in: tree, at: "new/TruongCleaner.app", spec)
            await #expect(throws: UpdateError.needsNewerSystem("27.1")) {
                try await verifier.verify(app, against: .fixture)
            }
        }
    }

    @Test func verify_acceptsAnUpdateThatNeedsExactlyTheRunningMacOS() async throws {
        try await withUpdateTree { tree in
            var spec = FixtureApp.Spec()
            spec.minimumSystem = "26.0"
            let app = try FixtureApp.make(in: tree, at: "new/TruongCleaner.app", spec)
            let identity = UpdateIdentity(
                bundleIdentifier: FixtureApp.ourID, bundleVersion: 1000, system: SystemVersion(major: 26))
            _ = try await verifier.verify(app, against: identity)
        }
    }

    @Test func verify_refusesAnExecutableWithoutArm64Code() async throws {
        try await withUpdateTree { tree in
            var spec = FixtureApp.Spec()
            spec.architecture = "x86_64"
            spec.sign = false
            let app = try FixtureApp.make(in: tree, at: "new/TruongCleaner.app", spec)
            await #expect(throws: UpdateError.wrongArchitecture) {
                try await verifier.verify(app, against: .fixture)
            }
        }
    }

    @Test func verify_refusesABundleWithoutAnExecutable() async throws {
        try await withUpdateTree { tree in
            let app = try FixtureApp.stub(in: tree, at: "new/TruongCleaner.app")
            await #expect(throws: UpdateError.unreadableBundle) {
                try await verifier.verify(app, against: .fixture)
            }
        }
    }

    @Test func verify_refusesABrokenSignature() async throws {
        try await withUpdateTree { tree in
            let app = try FixtureApp.make(in: tree, at: "new/TruongCleaner.app")
            // Sanity: the untouched bundle passes.
            _ = try await verifier.verify(app, against: .fixture)
            try FixtureApp.tamper(app)
            await #expect(throws: UpdateError.invalidSignature) {
                try await verifier.verify(app, against: .fixture)
            }
        }
    }

    @Test func verify_refusesAnUnsignedBundle() async throws {
        try await withUpdateTree { tree in
            // The linker signs arm64 executables ad hoc; remove that, so the bundle has no signature.
            let app = try FixtureApp.make(in: tree, at: "new/TruongCleaner.app", FixtureApp.Spec(sign: false))
            try runFixtureTool("/usr/bin/codesign", ["--remove-signature", app.appending(path: "Contents/MacOS/TruongCleaner").path(percentEncoded: false)])
            await #expect(throws: UpdateError.invalidSignature) {
                try await verifier.verify(app, against: .fixture)
            }
        }
    }

    @Test func verify_removesTheQuarantineFlagEverywhereInTheBundle() async throws {
        try await withUpdateTree { tree in
            let app = try FixtureApp.make(in: tree, at: "new/TruongCleaner.app")
            let executable = app.appending(path: "Contents/MacOS/TruongCleaner")
            let value = Array("0083;5f000000;Safari;".utf8)
            for url in [app, executable] {
                let status = setxattr(url.path(percentEncoded: false), "com.apple.quarantine", value, value.count, 0, 0)
                try #require(status == 0)
            }

            _ = try await verifier.verify(app, against: .fixture)

            for url in [app, executable] {
                let status = getxattr(url.path(percentEncoded: false), "com.apple.quarantine", nil, 0, 0, 0)
                #expect(status == -1 && errno == ENOATTR)
            }
        }
    }

    @Test func systemVersion_parsesAndOrders() {
        #expect(SystemVersion(string: "26.0") == SystemVersion(major: 26))
        #expect(SystemVersion(string: "26") == SystemVersion(major: 26))
        #expect(SystemVersion(string: "26.1.2") == SystemVersion(major: 26, minor: 1, patch: 2))
        #expect(SystemVersion(string: "") == nil)
        #expect(SystemVersion(string: "26.x") == nil)
        #expect(SystemVersion(string: "1.2.3.4") == nil)
        #expect(SystemVersion(major: 26, minor: 1) > SystemVersion(major: 26))
        #expect(SystemVersion(major: 27) > SystemVersion(major: 26, minor: 9, patch: 9))
    }
}
