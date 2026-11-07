/// Small builders that keep the per-category catalog files readable.
/// Internal to `CleanerCore`; the public surface is `Catalog.all`.

extension RootSpec {
    /// A root below the user's home folder, such as `["Library", "Caches"]`.
    static func home(_ components: [String]) -> RootSpec {
        RootSpec(base: .home, components: components)
    }

    /// A root below the file system root, such as `["Library", "Logs"]` for `/Library/Logs`.
    static func absolute(_ components: [String]) -> RootSpec {
        RootSpec(base: .absolute, components: components)
    }

    /// A root below `DARWIN_USER_CACHE_DIR`. No components means the directory itself.
    static func darwinCache(_ components: [String] = []) -> RootSpec {
        RootSpec(base: .darwinUserCache, components: components)
    }

    /// A root below `DARWIN_USER_TEMP_DIR`. No components means the directory itself.
    static func darwinTemp(_ components: [String] = []) -> RootSpec {
        RootSpec(base: .darwinUserTemp, components: components)
    }
}

extension Duration {
    /// A span of whole days, for `minAge` guards.
    static func days(_ count: Int64) -> Duration {
        .seconds(count * 86_400)
    }
}
