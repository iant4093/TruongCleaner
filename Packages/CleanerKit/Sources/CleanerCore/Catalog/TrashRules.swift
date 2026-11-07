/// Rules from `docs/RULE_CATALOG.md` §4.3 (Trash), in catalog order.
enum TrashRules {
    /// Every rule in the Trash section.
    static let all: [Rule] = [
        trashUser,
        trashOurs,
        trashVolumes,
    ]

    /// Each child of `~/.Trash`.
    ///
    /// `Action` has no "permanent delete" case, so the action is `.trash`. Moving an item that
    /// is already in the Trash is meaningless: the executor must treat this rule as
    /// permanent-delete only, behind the explicit confirmation in `safety.md` rule 11.
    static let trashUser = Rule(
        id: "trash.user",
        category: .trash,
        tier: .review,
        roots: [.home([".Trash"])],
        match: .children,
        access: .fda,
        action: .trash,
        title: "Trash",
        explain: "Files you already deleted. Emptying cannot be undone."
    )

    /// Placeholder. Offers nothing from the matcher.
    ///
    /// The real items come from the history file (what TruongCleaner moved, still in the Trash
    /// with the same file ID), not from a scan. Wave 3.3 replaces the matching. The root is the
    /// Trash folder where those items live.
    static let trashOurs = Rule(
        id: "trash.ours",
        category: .trash,
        tier: .safe,
        roots: [.home([".Trash"])],
        match: .measureOnly,
        access: .user,
        action: .trash,
        title: "Items TruongCleaner moved",
        explain: "Finish a clean and free the space."
    )

    /// Placeholder. Offers nothing yet.
    ///
    /// The catalog root is `/Volumes/*/.Trashes/<uid>`, where `<uid>` is the current user's ID.
    /// `RootSpec` has no user ID component. The closest root without it would include other
    /// users' trash folders, which is broader, so the root stops at `.Trashes` and the rule only
    /// measures until the model gains a user-ID base.
    static let trashVolumes = Rule(
        id: "trash.volumes",
        category: .trash,
        tier: .review,
        roots: [.absolute(["Volumes", "*", ".Trashes"])],
        match: .measureOnly,
        access: .user,
        action: .trash,
        title: "Trash on external drives",
        explain: "Trash on external drives."
    )
}
