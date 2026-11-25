import Foundation

/// A folder that isn't a git repository itself but holds several side by side (frontend/, backend/): a project made of
/// several repositories, or a branch group of such a project, which holds a worktree of each. Each repository inside is
/// a git place of its own, named by the key of the record that holds it ("<id>/<folder name>"), so git methods,
/// watches, pull requests and CI take it as they take a workspace's id, and a project's id the same way names the
/// repository's main checkout (`Store.repo`).
public enum RepoKey {
    /// The key of repository `name` inside the folder of record `id` (a workspace or a project).
    public static func of(_ id: String, _ name: String) -> String { id + "/" + name }
    /// The record's id and the repository's folder name in a key that `of` made; nil for any other id.
    public static func parts(_ key: String) -> (id: String, name: String)? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        let id = String(key[..<slash]), name = String(key[key.index(after: slash)...])
        return id.isEmpty || name.isEmpty ? nil : (id, name)
    }
}
