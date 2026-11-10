import Foundation

/// Rules from `docs/RULE_CATALOG.md` §4.7 (Mail and Messages), in catalog order.
///
/// Mail's and Messages' own data stays protected (`~/Library/Mail`, `~/Library/Messages`). The two
/// Messages folders that `messagesPreviews` cleans are carved out of that protection on purpose.
enum MailRules {
    /// Every rule in the Mail and Messages section.
    static let all: [Rule] = [
        mailDownloads,
        mailCaches,
        mailStore,
        messagesPreviews,
        messagesAttachments,
    ]

    private static let mailOwner: [OwnerSpec] = [.bundleID("com.apple.mail")]
    private static let messagesOwner: [OwnerSpec] = [.bundleID("com.apple.MobileSMS")]

    /// Each child of Mail's attachment copies, older than 30 days.
    ///
    /// Review, not Safe: a saved edit of an attachment stays in this folder and may be the only copy.
    /// The catalog asks that the file was not modified after it was created. The scan does not read
    /// creation dates, so `SafetyGate` checks it just before acting (`DenyReason.editedAfterDownload`),
    /// and the item is never pre-selected.
    static let mailDownloads = Rule(
        id: "mail.downloads",
        category: .mail,
        tier: .review,
        roots: [.home(["Library", "Containers", "com.apple.mail", "Data", "Library", "Mail Downloads"])],
        match: .children,
        guards: Guards(minAge: .days(30), owners: mailOwner),
        access: .fda,
        action: .trash,
        title: "Mail attachment copies",
        explain: "Copies of attachments you opened. The originals stay in Mail."
    )

    /// Each child of Mail's cache folder.
    static let mailCaches = Rule(
        id: "mail.caches",
        category: .mail,
        tier: .safe,
        roots: [.home(["Library", "Caches", "com.apple.mail"])],
        match: .children,
        guards: Guards(owners: mailOwner),
        access: .fda,
        action: .trash,
        title: "Mail cache",
        explain: "Mail's cache."
    )

    /// Info only: the mail store itself.
    static let mailStore = Rule(
        id: "mail.store",
        category: .mail,
        tier: .info,
        roots: [.home(["Library", "Mail"])],
        match: .measureOnly,
        access: .fda,
        action: .none,
        title: "Mail",
        explain: "Your email. To free space, use Mail > Mailbox > Erase Deleted Items."
    )

    /// Each child of the Messages link-preview folder and the sticker cache.
    static let messagesPreviews = Rule(
        id: "mail.messagesPreviews",
        category: .mail,
        tier: .safe,
        roots: [
            .home(["Library", "Messages", "Caches", "Previews"]),
            .home(["Library", "Messages", "StickerCache"]),
        ],
        match: .children,
        guards: Guards(owners: messagesOwner),
        access: .fda,
        action: .trash,
        title: "Messages previews",
        explain: "Link and sticker previews."
    )

    /// Info only: photos and files from chats.
    static let messagesAttachments = Rule(
        id: "mail.messagesAttachments",
        category: .mail,
        tier: .info,
        roots: [.home(["Library", "Messages", "Attachments"])],
        match: .measureOnly,
        access: .fda,
        action: .none,
        title: "Messages attachments",
        explain: "Your photos and files from chats. To free space, use System Settings > Storage > Messages.",
        settingsURL: URL(string: "x-apple.systempreferences:com.apple.settings.Storage")
    )
}
