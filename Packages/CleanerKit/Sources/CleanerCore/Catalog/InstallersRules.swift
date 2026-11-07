/// Rules from `docs/RULE_CATALOG.md` §4.9 (Installers and downloads), in catalog order.
enum InstallersRules {
    /// Every rule in the Installers and downloads section.
    static let all: [Rule] = [
        macOSInstallers,
        downloadedInstallers,
        partialDownloads,
    ]

    /// `Install macOS *.app` in `/Applications`, older than 14 days. The whole app is the item.
    /// This is the only rule that may remove a whole `.app` (`Rule.allowsWholeBundle`).
    ///
    /// The catalog also asks for an Apple signature and for keeping the installer of a pending
    /// update. Neither can be checked here (no code-signature or update-state reading in the
    /// scan), so only the age guard applies.
    static let macOSInstallers = Rule(
        id: "installers.macOS",
        category: .installers,
        tier: .review,
        roots: [.absolute(["Applications"])],
        match: .glob("Install macOS*.app"),
        guards: Guards(minAge: .days(14)),
        access: .user,
        action: .trash,
        title: "macOS installers",
        explain: "macOS installer apps you can download again."
    )

    /// Disk images and packages directly in `~/Downloads`, older than 7 days.
    static let downloadedInstallers = Rule(
        id: "installers.downloads",
        category: .installers,
        tier: .review,
        roots: [.home(["Downloads"])],
        match: .files(extensions: ["dmg", "pkg", "mpkg", "iso", "xip"]),
        guards: Guards(minAge: .days(7)),
        access: .user,
        action: .trash,
        title: "Installers in Downloads",
        explain: "Installers you already used."
    )

    /// Unfinished downloads directly in `~/Downloads`, older than a day. Safari's `.download` is a
    /// folder and the other two are files, so the match is a glob, not a file-extension match.
    static let partialDownloads = Rule(
        id: "installers.partial",
        category: .installers,
        tier: .safe,
        roots: [.home(["Downloads"])],
        match: .glob("*.{download,crdownload,part}"),
        guards: Guards(minAge: .days(1)),
        access: .user,
        action: .trash,
        title: "Unfinished downloads",
        explain: "Unfinished browser downloads."
    )
}
