/// The rules the app ships. Built from the per-category files in this folder.
///
/// A rule that is not listed in `docs/RULE_CATALOG.md` does not ship.
public enum Catalog {
    /// Every shipped rule, in catalog order. Waves after 3.2 append the remaining categories.
    public static let all: [Rule] = CachesRules.all
        + LogsRules.all
        + TrashRules.all
        + BrowserRules.all
        + AppRules.all
}
