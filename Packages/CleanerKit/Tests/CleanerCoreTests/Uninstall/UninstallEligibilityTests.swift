import Foundation
import Testing

@testable import CleanerCore

/// `docs/UNINSTALLER.md` §1: which apps are refused.
struct UninstallEligibilityTests {
    private typealias Fixtures = UninstallFixtures

    private func check(_ app: AppFacts, running: Bool? = false, context: UninstallContext = Fixtures.context())
        -> UninstallRefusal?
    {
        UninstallEligibility.check(app, isRunning: running, context: context)
    }

    @Test func anOrdinaryAppInApplicationsIsEligible() {
        #expect(check(Fixtures.app()) == nil)
    }

    @Test func anAppOneLevelBelowApplicationsIsEligible() {
        #expect(check(Fixtures.app(path: "/Applications/Vendor/Foo.app")) == nil)
        #expect(check(Fixtures.app(path: "/Users/test/Applications/Foo.app")) == nil)
    }

    @Test func appsUnderSystemAreRefused() {
        #expect(check(Fixtures.app("com.vendor.Thing", path: "/System/Applications/Thing.app")) == .systemApp)
        #expect(check(Fixtures.app("com.vendor.Thing", path: "/System/Library/CoreServices/Thing.app")) == .systemApp)
        #expect(UninstallRefusal.systemApp.isApple)
    }

    @Test func incident_pearcleaner618_appleAppsAreRefusedByBundleID() {
        for id in ["com.apple.Safari", "com.apple.dt.Xcode", "COM.APPLE.Notes"] {
            #expect(check(Fixtures.app(id, path: "/Applications/Apple.app")) == .apple, "\(id)")
        }
        #expect(UninstallRefusal.apple.isApple)
    }

    @Test func incident_pearcleaner618_appleSignedAppsAreRefusedWhateverTheirID() {
        #expect(check(Fixtures.app("org.example.Renamed", signature: .apple)) == .apple)
    }

    @Test func aBundleIDThatOnlyStartsLikeAppleIsNotApple() {
        #expect(check(Fixtures.app("com.applesauce.Foo")) == nil)
        #expect(check(Fixtures.app("com.apple")) == nil)
    }

    @Test func anUnreadableSignatureRefusesTheApp() {
        #expect(check(Fixtures.app(signature: .unknown)) == .signatureUnknown)
    }

    @Test func truongCleanerItselfIsRefusedByIDAndByLocation() {
        let context = Fixtures.context(
            ownBundleURL: URL(filePath: "/Applications/Renamed Cleaner.app", directoryHint: .isDirectory))
        #expect(check(Fixtures.app("com.iant4093.TruongCleaner"), context: context) == .thisApp)
        #expect(check(Fixtures.app("COM.IANT4093.TRUONGCLEANER"), context: context) == .thisApp)
        #expect(check(Fixtures.app("org.fork.Other", path: "/Applications/Renamed Cleaner.app"), context: context) == .thisApp)
        #expect(!UninstallRefusal.thisApp.isApple)
    }

    @Test func anAppWithoutABundleIDIsRefused() {
        #expect(check(Fixtures.app(nil)) == .noBundleID)
        #expect(check(Fixtures.app("")) == .noBundleID)
    }

    @Test func incident_mole1854_aRunningAppIsRefused() {
        #expect(check(Fixtures.app(), running: true) == .running)
    }

    @Test func incident_mole1854_anUnknownRunStateIsRefused() {
        #expect(check(Fixtures.app(), running: nil) == .runningUnknown)
    }

    @Test(arguments: [
        "/Users/test/Downloads/Foo.app",
        "/Users/test/Desktop/Foo.app",
        "/opt/homebrew/Caskroom/Foo.app",
        "/Applications/A/B/Foo.app",
        "/Foo.app",
    ])
    func appsOutsideTheApplicationFoldersAreRefused(path: String) {
        #expect(check(Fixtures.app(path: path)) == .outsideApplicationFolders)
    }

    @Test(arguments: ["/Applications/../Users/Foo.app", "/Applications/./Foo.app"])
    func pathsWithDotComponentsAreUnreadable(path: String) {
        #expect(check(Fixtures.app(path: path)) == .unreadable)
    }

    @Test func aRelativeOrNonFileURLIsUnreadable() {
        var app = Fixtures.app()
        app.url = URL(string: "https://example.com/Foo.app")!
        #expect(check(app) == .unreadable)
    }

    @Test func rootOwnedOrNonWritableAppsNeedAnAdministrator() {
        #expect(check(Fixtures.app(owner: 0)) == .needsAdministrator)
        #expect(check(Fixtures.app(owner: 502)) == .needsAdministrator)
        #expect(check(Fixtures.app(writable: false)) == .needsAdministrator)
    }

    @Test func unknownOwnershipRefusesTheApp() {
        #expect(check(Fixtures.app(owner: nil)) == .ownerUnknown)
        #expect(check(Fixtures.app(writable: nil)) == .ownerUnknown)
    }

    @Test func refusalsHaveAReasonInPlainWords() {
        let all: [UninstallRefusal] = [
            .systemApp, .apple, .signatureUnknown, .thisApp, .running, .runningUnknown, .noBundleID,
            .outsideApplicationFolders, .needsAdministrator, .ownerUnknown, .unreadable,
        ]
        for refusal in all { #expect(!refusal.message.isEmpty) }
        #expect(Set(all.map(\.message)).count == all.count)
        #expect(UninstallRefusal.needsAdministrator.message == "Needs an administrator")
    }
}
