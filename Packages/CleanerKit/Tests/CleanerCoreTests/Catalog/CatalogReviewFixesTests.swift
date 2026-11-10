import Foundation
import Testing

@testable import CleanerCore

/// Review fixes 1 and 4: catalog rows.
struct CatalogReviewFixesTests {
    @Test func mailDownloadsIsReviewSoItIsNeverPreselected() throws {
        let rule = try CatalogFixture.rule("mail.downloads")
        #expect(rule.tier == .review)
        #expect(rule.guards.minAge == .days(30))
        #expect(rule.guards.owners == [.bundleID("com.apple.mail")])
    }

    @Test func adobeMediaCacheNamesItsAppsByBundleIDPrefixNotByProcessName() throws {
        let owners = try CatalogFixture.rule("apps.adobeMediaCache").guards.owners
        #expect(owners.contains(.bundleID("com.adobe.PremierePro.*")))
        for owner in owners {
            guard case .bundleID(let id) = owner else {
                Issue.record("Adobe rule still has a name-only owner: \(owner)")
                continue
            }
            #expect(id.hasPrefix("com.adobe.") && id.hasSuffix("*"), "\(id)")
        }
    }

    @Test func ownersThatRunUnderAnotherNameAreStillNamedByTheTool() throws {
        // The matcher in CleanerActions finds these by argument vector (npm runs as `node`).
        let expected = [
            "dev.swiftpm": "swift", "dev.npm": "npm", "dev.yarn": "yarn", "dev.gradle": "gradle", "dev.cocoapods": "pod",
        ]
        for (id, name) in expected {
            #expect(try CatalogFixture.rule(id).guards.owners == [.processName(name)], "\(id)")
        }
    }
}
