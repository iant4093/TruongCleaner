/// Rules from `docs/RULE_CATALOG.md` §4.2 (Logs and crash reports), in catalog order.
///
/// The file rules use `.files(extensions:)` instead of `.glob`: the matcher checks "is a
/// file" only for `.files`, and a glob would also match folders. Using it keeps every folder
/// (including the rule root) out of the results by construction. The extension lists are
/// narrower than "any file"; a log with another extension is kept.
enum LogsRules {
    /// Every rule in the Logs section.
    static let all: [Rule] = [
        logsUser,
        logsUserCrash,
        logsCrashReporter,
        logsCoreSimulator,
        logsSystem,
        logsUnified,
    ]

    /// Log files up to two levels below `~/Library/Logs`, older than 7 days. Folders stay.
    /// TruongCleaner's own log folder is skipped.
    static let logsUser = Rule(
        id: "logs.user",
        category: .logs,
        tier: .safe,
        roots: [.home(["Library", "Logs"])],
        match: .files(extensions: ["log", "txt", "out", "err", "old", "gz"]),
        depth: 2,
        guards: Guards(minAge: .days(7), excludeNames: ["TruongCleaner"]),
        access: .user,
        action: .trash,
        title: "App logs",
        explain: "Old app log files."
    )

    /// Crash report files directly in `DiagnosticReports`, older than 7 days. The folder and
    /// its subfolders stay.
    static let logsUserCrash = Rule(
        id: "logs.userCrash",
        category: .logs,
        tier: .safe,
        roots: [.home(["Library", "Logs", "DiagnosticReports"])],
        match: .files(extensions: ["ips", "crash", "diag", "spin", "hang", "panic"]),
        guards: Guards(minAge: .days(7)),
        access: .user,
        action: .trash,
        title: "Crash reports",
        explain: "Old crash reports."
    )

    /// Files directly in `~/Library/Application Support/CrashReporter`, older than 30 days.
    /// The folder holds `.plist` records; the crash extensions are listed in case reports land here.
    static let logsCrashReporter = Rule(
        id: "logs.crashReporter",
        category: .logs,
        tier: .safe,
        roots: [.home(["Library", "Application Support", "CrashReporter"])],
        match: .files(extensions: ["plist", "crash", "ips", "diag"]),
        guards: Guards(minAge: .days(30)),
        access: .user,
        action: .trash,
        title: "Crash reporter data",
        explain: "Old crash reporter data."
    )

    /// Each child of `~/Library/Logs/CoreSimulator`, older than 7 days.
    static let logsCoreSimulator = Rule(
        id: "logs.coreSimulator",
        category: .logs,
        tier: .safe,
        roots: [.home(["Library", "Logs", "CoreSimulator"])],
        match: .children,
        guards: Guards(minAge: .days(7)),
        access: .user,
        action: .trash,
        title: "Simulator logs",
        explain: "Simulator logs."
    )

    /// Info only: system logs need root.
    static let logsSystem = Rule(
        id: "logs.system",
        category: .logs,
        tier: .info,
        roots: [.absolute(["Library", "Logs"]), .absolute(["private", "var", "log"])],
        match: .measureOnly,
        access: .root,
        action: .none,
        title: "System logs",
        explain: "System logs; macOS rotates them."
    )

    /// Info only: the unified log is protected by SIP and trimmed by `logd`.
    static let logsUnified = Rule(
        id: "logs.unified",
        category: .logs,
        tier: .info,
        roots: [
            .absolute(["private", "var", "db", "diagnostics"]),
            .absolute(["private", "var", "db", "uuidtext"]),
        ],
        match: .measureOnly,
        access: .root,
        action: .none,
        title: "Unified system log",
        explain: "The system log. logd trims it itself."
    )
}
