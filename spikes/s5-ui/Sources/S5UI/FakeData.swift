import SwiftUI

// Static fake data for the prototype. Nothing here reads the disk.

enum Tier: Sendable {
    case safe, review, info

    var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .info: "Info"
        }
    }
}

struct CleanChild: Identifiable, Sendable {
    let id: String
    let name: String
    let gigabytes: Double
}

struct CleanItem: Identifiable, Sendable {
    let id: String
    let title: String
    let explain: String
    let gigabytes: Double
    let tier: Tier
    let symbol: String
    let color: Color
    var children: [CleanChild] = []
}

struct CleanGroup: Identifiable, Sendable {
    let title: String
    let items: [CleanItem]
    var id: String { title }
}

struct StorageSegment: Identifiable, Sendable {
    let name: String
    let gigabytes: Double
    var id: String { name }
}

struct Recommendation: Identifiable, Sendable {
    let id: String
    let symbol: String
    let color: Color
    let text: String
}

struct SystemRow: Identifiable, Sendable {
    let id: String
    let title: String
    let explain: String
    let symbol: String
    let color: Color
    let value: String
    let tier: Tier
    let action: String
    var needsAccess = false
}

enum FakeData {
    static let volumeName = "Macintosh HD"
    static let totalGB = 994.7
    static let usedGB = 460.3
    static let availableGB = 534.4

    /// Segments sum to `usedGB`, then Free fills the rest.
    static let segments: [StorageSegment] = [
        .init(name: "Apps", gigabytes: 92.1),
        .init(name: "Documents", gigabytes: 61.4),
        .init(name: "Developer", gigabytes: 118.6),
        .init(name: "Caches", gigabytes: 24.3),
        .init(name: "iOS Backups", gigabytes: 41.0),
        .init(name: "System", gigabytes: 99.5),
        .init(name: "Unexplained", gigabytes: 23.4),
        .init(name: "Free", gigabytes: availableGB),
    ]

    static let recommendations: [Recommendation] = [
        .init(id: "r1", symbol: "sparkles", color: .blue, text: "Smart Clean can free about 22.4 GB"),
        .init(id: "r2", symbol: "hammer.fill", color: .indigo, text: "Xcode DerivedData uses 9.1 GB"),
        .init(id: "r3", symbol: "iphone", color: .green, text: "2 iPhone backups use 41 GB"),
    ]

    static let cleanGroups: [CleanGroup] = [
        .init(title: "Caches", items: [
            .init(id: "caches.app", title: "App caches",
                  explain: "Apps keep temporary copies here and rebuild them.",
                  gigabytes: 4.1, tier: .safe, symbol: "archivebox.fill", color: .teal),
            .init(id: "caches.quicklook", title: "Quick Look thumbnails",
                  explain: "Finder preview images. They are made again when needed.",
                  gigabytes: 0.3, tier: .safe, symbol: "doc.text.fill", color: .teal),
        ]),
        .init(title: "Logs", items: [
            .init(id: "logs.old", title: "Old log files",
                  explain: "App logs older than 7 days.",
                  gigabytes: 0.6, tier: .safe, symbol: "doc.text.fill", color: .gray),
        ]),
        .init(title: "Browsers", items: [
            .init(id: "browser.safari", title: "Safari cache",
                  explain: "Web pages and images saved for speed. Sign-ins stay.",
                  gigabytes: 1.2, tier: .safe, symbol: "globe", color: .blue),
            .init(id: "browser.chromium", title: "Chrome cache",
                  explain: "Web and graphics caches. Sign-ins and tabs stay.",
                  gigabytes: 2.4, tier: .safe, symbol: "globe", color: .blue),
        ]),
        .init(title: "Developer", items: [
            .init(id: "dev.derived", title: "Xcode DerivedData",
                  explain: "Build products. Xcode rebuilds them.",
                  gigabytes: 9.1, tier: .safe, symbol: "hammer.fill", color: .indigo,
                  children: [
                      .init(id: "dd1", name: "TruongCam-bxkqf", gigabytes: 5.2),
                      .init(id: "dd2", name: "TruongCleaner-hdnwe", gigabytes: 2.6),
                      .init(id: "dd3", name: "ModuleCache.noindex", gigabytes: 1.3),
                  ]),
            .init(id: "dev.devicesupport", title: "Xcode device support",
                  explain: "Debug symbols copied from devices. The newest 2 are kept.",
                  gigabytes: 3.3, tier: .safe, symbol: "hammer.fill", color: .indigo),
            .init(id: "dev.archives", title: "Xcode archives",
                  explain: "Apps you exported. They hold crash symbols for shipped versions.",
                  gigabytes: 2.8, tier: .review, symbol: "shippingbox.fill", color: .indigo),
            .init(id: "dev.homebrew", title: "Homebrew downloads",
                  explain: "Old downloads and versions. Runs brew cleanup.",
                  gigabytes: 1.1, tier: .safe, symbol: "shippingbox.fill", color: .orange),
        ]),
        .init(title: "iOS Devices", items: [
            .init(id: "ios.backups", title: "iPhone and iPad backups",
                  explain: "Backups of your devices. This may be your only copy.",
                  gigabytes: 41.0, tier: .review, symbol: "iphone", color: .green),
        ]),
        .init(title: "Mail", items: [
            .init(id: "mail.store", title: "Mail messages",
                  explain: "Your email. Use Mail > Mailbox > Erase Deleted Items to shrink it.",
                  gigabytes: 12.6, tier: .info, symbol: "envelope.fill", color: .blue),
        ]),
    ]

    /// Safe items start selected; Review and Info do not.
    static let defaultSelection: Set<String> = Set(
        cleanGroups.flatMap(\.items).filter { $0.tier == .safe }.map(\.id)
    )

    static let systemRows: [SystemRow] = [
        .init(id: "snapshots", title: "Local snapshots",
              explain: "7 Time Machine snapshots. macOS removes them when it needs space.",
              symbol: "clock.arrow.circlepath", color: .teal, value: "Unknown", tier: .info,
              action: "Copy Command"),
        .init(id: "purgeable", title: "Purgeable space",
              explain: "macOS frees this on its own when an app needs room.",
              symbol: "internaldrive.fill", color: .gray, value: sizeText(12.0), tier: .info,
              action: "Learn More"),
        .init(id: "spotlight", title: "Spotlight index",
              explain: "Search index. Rebuilding it takes hours.",
              symbol: "magnifyingglass", color: .gray, value: "Unknown", tier: .info,
              action: "Copy Command"),
        .init(id: "swap", title: "Swap",
              explain: "Memory pushed to disk. Quit heavy apps or restart to shrink it.",
              symbol: "memorychip.fill", color: .gray, value: sizeText(3.2), tier: .info,
              action: "Learn More"),
        .init(id: "ai", title: "Apple Intelligence assets",
              explain: "On-device models. Manage languages in System Settings.",
              symbol: "brain", color: .purple, value: sizeText(4.8), tier: .info,
              action: "Open Settings"),
        .init(id: "updates", title: "System updates",
              explain: "Staged macOS updates. Finish the update; never delete these.",
              symbol: "arrow.down.circle.fill", color: .gray, value: "Unknown", tier: .info,
              action: "Learn More"),
        .init(id: "mailaccess", title: "Mail store",
              explain: "Reading this folder needs Full Disk Access.",
              symbol: "envelope.fill", color: .blue, value: "Needs Full Disk Access", tier: .info,
              action: "Open Settings", needsAccess: true),
    ]
}
