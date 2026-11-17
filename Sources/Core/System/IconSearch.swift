import Foundation

/// Finds a project's own icon in the places web, desktop, Android and Xcode projects keep theirs, at the top or in one
/// of the project's folders (a monorepo's `frontend/public/`, an app's `Resources/`, an Android module's
/// `src/main/res/`). The search works the same way in a project on this Mac (`ProjectIcon`) and on a host
/// (`repo.icon`).
public enum IconSearch {
    /// Where icons are kept, relative to the project or one of its top folders.
    public static let places = [
        "", "public/", "static/", "app/", "src/app/", "src/assets/", "assets/", "Assets/", "Resources/",
        "img/", "images/", "icons/", "build/", "src-tauri/icons/", "docs/", ".github/",
        "src/main/res/mipmap-xxxhdpi/", "src/main/res/mipmap-xxhdpi/"
    ]
    /// The usual icon file names, best first. After these come any other `.icns`, then an Xcode AppIcon set, then an
    /// image named after the project.
    public static let names = [
        "AppIcon.icns", "icon.icns", "apple-touch-icon.png", "favicon.svg", "icon.svg", "icon.png",
        "favicon.png", "favicon.ico", "ic_launcher.png", "ic_launcher.webp", "logo.svg", "logo.png"
    ]
    static let imageTypes: Set = ["svg", "png", "ico", "icns", "webp"]

    /// Finds the project's icon: the project's own usual places first, then those in each top-level folder, looking
    /// only so far. `name` is the project's name (its folder's name by default). `list` gives the names in a folder
    /// (nil when there is no such folder) and `size` gives a file's size in bytes; both read this Mac's disk unless a
    /// host's listing is passed in.
    public static func find(
        in repo: String, name: String? = nil,
        list: (String) -> [String]? = { try? FileManager.default.contentsOfDirectory(atPath: $0) },
        size: (String) -> Int = { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int) ?? 0 }
    ) -> String? {
        let words = (name ?? (repo as NSString).lastPathComponent).lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
        // A folder that is a repository of its own is another project, so its icon isn't this project's. A home folder
        // holding projects used to take the first project's icon.
        let tops = (list(repo) ?? []).filter { !$0.hasPrefix(".") && $0 != "node_modules" }.sorted().prefix(40)
            .filter { list(repo + "/" + $0 + "/")?.contains(".git") != true }
        for base in [""] + tops.map({ $0 + "/" }) {
            let dirs = places.compactMap { p -> (String, [String])? in
                let dir = repo + "/" + base + p
                return list(dir).map { (dir, $0) }
            }
            for name in names { if let (dir, _) = dirs.first(where: { $0.1.contains(name) }) { return dir + name } }
            for (dir, files) in dirs {
                if let icns = files.sorted().first(where: { $0.hasSuffix(".icns") }) { return dir + icns }
            }
            for (dir, files) in dirs where files.contains("Assets.xcassets") {
                // For an Xcode AppIcon set, take its largest PNG.
                let set = dir + "Assets.xcassets/AppIcon.appiconset"
                if let png = (list(set) ?? []).filter({ $0.hasSuffix(".png") }).max(by: {
                    size(set + "/" + $0) < size(set + "/" + $1)
                }) {
                    return set + "/" + png
                }
            }
            // Take a site's icon named after the project (`pretype-icon.svg`), never another brand's
            // (`github-icon.svg`).
            for kind in ["icon", "logo"] {
                for (dir, files) in dirs {
                    if let file = files.sorted().first(where: { ownImage($0, kind, words) }) { return dir + file }
                }
            }
        }
        return nil
    }

    private static func ownImage(_ file: String, _ kind: String, _ words: [String]) -> Bool {
        let name = file.lowercased()
        return name.contains(kind) && imageTypes.contains((name as NSString).pathExtension)
            && words.contains { name.contains($0) }
    }
}
