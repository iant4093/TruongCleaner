/// Rules from `docs/RULE_CATALOG.md` §4.8 (iOS devices), in catalog order.
enum IOSRules {
    /// Every rule in the iOS devices section.
    static let all: [Rule] = [
        backups,
        firmware,
    ]

    /// Each backup folder under `MobileSync/Backup`. Never selected by default.
    /// The UI reads the device name and date from each backup's `Info.plist`.
    static let backups = Rule(
        id: "ios.backups",
        category: .ios,
        tier: .review,
        roots: [.home(["Library", "Application Support", "MobileSync", "Backup"])],
        match: .children,
        access: .fda,
        action: .trash,
        title: "iPhone and iPad backups",
        explain: "Backups of your iPhone or iPad. May be your only copy."
    )

    /// `.ipsw` files in the four `Software Updates` folders.
    static let firmware = Rule(
        id: "ios.firmware",
        category: .ios,
        tier: .safe,
        roots: ["iPhone", "iPad", "iPod", "Apple TV"].map {
            .home(["Library", "iTunes", "\($0) Software Updates"])
        },
        match: .files(extensions: ["ipsw"]),
        access: .user,
        action: .trash,
        title: "Device software downloads",
        explain: "Downloaded iOS installers; Finder downloads them again."
    )
}
