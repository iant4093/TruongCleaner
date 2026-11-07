/// The rules the app ships. Built from the per-category files in this folder.
///
/// A rule that is not listed in `docs/RULE_CATALOG.md` does not ship.
public enum Catalog {
    /// Every shipped rule, in catalog order (`docs/RULE_CATALOG.md` §4.1 to §4.10).
    public static let all: [Rule] = CachesRules.all
        + LogsRules.all
        + TrashRules.all
        + BrowserRules.all
        + AppRules.all
        + DeveloperRules.all
        + MailRules.all
        + IOSRules.all
        + InstallersRules.all
        + SystemRules.all
}
