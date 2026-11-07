import Foundation

/// Which category a folder belongs to. Pure lookups; no file access.
enum CategoryPlan {
    /// Category of a direct child folder of the home folder, or `nil` when it is not a named one.
    /// `Library` is handled separately because it is split further.
    static func homeCategory(forFolder name: String) -> StorageCategory? {
        switch name {
        case "Documents": .documents
        case "Downloads": .downloads
        case "Desktop": .desktop
        case "Pictures": .pictures
        case "Movies": .movies
        case "Music": .music
        case "Applications": .applications
        case ".Trash": .trash
        default: nil
        }
    }

    /// Folders inside `~/Library` that are measured as their own category, by path below `Library`.
    ///
    /// None of these paths contains another, so subtracting them from the Library total counts nothing twice.
    static let libraryCarveOuts: [String: StorageCategory] = [
        "Caches": .libraryCaches,
        "Developer": .developer,
        "Mobile Documents": .icloud,
        "Mail": .mail,
        "Messages": .messages,
        "Containers/com.apple.mail": .mail,
        "Application Support/MobileSync/Backup": .iosBackups,
    ]

    /// How deep the Library walk keeps folder totals: enough to reach the deepest carve-out.
    static let libraryTotalsDepth: Int = {
        libraryCarveOuts.keys.map { $0.split(separator: "/").count }.max() ?? 1
    }()

    /// Category of the Library entry at `relative` (path components below `Library`).
    /// The longest carve-out that is a prefix wins; anything else is `libraryOther`.
    static func libraryCategory(forRelative relative: some Collection<String>) -> StorageCategory {
        let parts = Array(relative)
        var length = min(parts.count, libraryTotalsDepth)
        while length > 0 {
            if let category = libraryCarveOuts[parts.prefix(length).joined(separator: "/")] { return category }
            length -= 1
        }
        return .libraryOther
    }

    /// Path components in a form that compares equal whatever Unicode normalization the file system used.
    static func normalized(_ components: some Sequence<String>) -> [String] {
        components.map { $0.precomposedStringWithCanonicalMapping }
    }
}
