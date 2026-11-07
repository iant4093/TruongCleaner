import CleanerCore
import CleanerScanner
import Foundation
import SwiftUI

/// What the size column of a System Data row says. A number that could not be read is never shown as zero.
nonisolated enum SystemDataValue: Equatable {
    /// A measured size in bytes.
    case size(Int64)
    /// Part of the folder could not be read, so the true size is at least this.
    case atLeast(Int64)
    /// Plain words instead of a number, such as "None" or "Not found".
    case text(String)
    /// The measurement failed, was cut short, or does not apply.
    case unknown
    /// macOS answered "not permitted" and Full Disk Access may fix that.
    case needsAccess
    /// Only macOS itself can read or change this.
    case macOSOnly

    /// Bytes that count toward the "measured" total, or `nil` for rows with no number.
    var countedBytes: Int64? {
        switch self {
        case .size(let bytes), .atLeast(let bytes): bytes
        default: nil
        }
    }

    /// The text shown in the row.
    var display: String {
        switch self {
        case .size(let bytes): ByteFormatter.string(bytes)
        case .atLeast(let bytes): "At least \(ByteFormatter.string(bytes))"
        case .text(let text): text
        case .unknown: "Unknown"
        case .needsAccess: "Needs Full Disk Access"
        case .macOSOnly: "macOS only"
        }
    }
}

/// Where a row sits on the page, and the color it has in the header bar.
nonisolated enum SystemDataSection: Int, CaseIterable, Identifiable {
    case macOS, developer, mail, logsAndCaches

    var id: Self { self }

    var title: String {
        switch self {
        case .macOS: "macOS"
        case .developer: "Developer"
        case .mail: "Mail and Messages"
        case .logsAndCaches: "Logs and caches"
        }
    }

    /// Segment color in the header bar.
    var color: Color {
        switch self {
        case .macOS: .gray
        case .developer: .indigo
        case .mail: .blue
        case .logsAndCaches: .teal
        }
    }

    /// The section a catalog rule belongs to.
    static func section(for category: CleanerCore.Category) -> SystemDataSection {
        switch category {
        case .developer: .developer
        case .mail: .mail
        case .caches, .logs: .logsAndCaches
        default: .macOS
        }
    }
}

/// One contributor to System Data: what it is, how big it is, and the one thing we offer for it.
nonisolated struct SystemDataRow: Identifiable {
    let id: String
    let section: SystemDataSection
    let symbol: String
    let color: Color
    let title: String
    /// One plain sentence: what it is and what to do about it.
    let explain: String
    /// Extra line under the explanation, such as why the Unexplained number is imprecise.
    var note: String?
    var value: SystemDataValue
    /// The System Settings pane that holds the sanctioned fix, for "Open Settings".
    let settingsURL: URL?
    /// The Terminal command for "Copy Command". The app never runs it.
    let command: String?
    /// Local snapshots, for the row that expands to list them. `nil` for every other row.
    var snapshots: [LocalSnapshot]?
    /// True when the size is part of what the Unexplained number subtracts.
    var countsTowardUsed: Bool
    /// True when the measured folder lies inside the home folder. The category measurement already
    /// contains it, so it is not subtracted a second time once categories are known.
    var isInsideHome = false

    /// Symbol and tile color for a rule.
    static func look(ruleID: String) -> (symbol: String, color: Color) {
        switch ruleID {
        case "system.snapshots": ("clock.arrow.circlepath", .teal)
        case "system.purgeable": ("arrow.triangle.2.circlepath", .orange)
        case "system.spotlight": ("magnifyingglass", .gray)
        case "system.swap": ("memorychip.fill", .pink)
        case "system.aiAssets": ("apple.intelligence", .purple)
        case "system.rosetta": ("cpu.fill", .gray)
        case "system.updates": ("arrow.down.circle.fill", .blue)
        case "system.unexplained": ("questionmark.circle.fill", .gray)
        case "system.libraryCaches": ("internaldrive.fill", .gray)
        case "logs.system", "logs.unified": ("doc.plaintext.fill", .gray)
        case "mail.store": ("envelope.fill", .blue)
        case "mail.messagesAttachments": ("message.fill", .green)
        case "dev.dockerImage": ("shippingbox.fill", .blue)
        case Self.simulatorRuntimesID: ("iphone", .indigo)
        default: ("gearshape.2.fill", .gray)
        }
    }

    /// ID of the row for the total size of installed simulator runtimes. It has no catalog rule.
    static let simulatorRuntimesID = "dev.simRuntimes.total"
}
