import Foundation

/// Where a project keeps its own icon: where web, desktop and Xcode projects keep theirs, at the top or in one of its
/// folders (a monorepo's `frontend/public/`, an app's `Resources/`). Looked for the same way in a project here
/// (`ProjectIcon`) and on a host (`repo.icon`).
public enum IconSearch {
    /// Where icons are kept, relative to the project or one of its top folders.
    public static let places = ["", "public/", "static/", "app/", "src/app/", "src/assets/", "assets/", "Assets/", "Resources/",
                                "img/", "images/", "icons/", "build/", "src-tauri/icons/", "docs/", ".github/"]
    /// What they're called, best first; any other `.icns`, then an Xcode AppIcon set, come after these.
    public static let names = ["AppIcon.icns", "icon.icns", "apple-touch-icon.png", "favicon.svg", "icon.svg", "icon.png",
                               "favicon.png", "favicon.ico", "logo.svg", "logo.png"]

    /// The project's own places first, then each top folder's. A bounded look. `list` gives a folder's names (nil: no
    /// such folder) and `size` a file's bytes: this Mac's, unless they're a host's listing.
    public static func find(in repo: String, list: (String) -> [String]? = { try? FileManager.default.contentsOfDirectory(atPath: $0) },
                            size: (String) -> Int = { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int) ?? 0 }) -> String? {
        let tops = (list(repo) ?? []).filter { !$0.hasPrefix(".") && $0 != "node_modules" }.sorted().prefix(40)
        for base in [""] + tops.map({ $0 + "/" }) {
            let dirs = places.compactMap { p -> (String, [String])? in
                let dir = repo + "/" + base + p
                return list(dir).map { (dir, $0) }
            }
            for n in names { if let (dir, _) = dirs.first(where: { $0.1.contains(n) }) { return dir + n } }
            for (dir, files) in dirs { if let icns = files.sorted().first(where: { $0.hasSuffix(".icns") }) { return dir + icns } }
            for (dir, files) in dirs where files.contains("Assets.xcassets") {
                // An Xcode AppIcon set: its largest PNG.
                let set = dir + "Assets.xcassets/AppIcon.appiconset"
                if let png = (list(set) ?? []).filter({ $0.hasSuffix(".png") }).max(by: { size(set + "/" + $0) < size(set + "/" + $1) }) {
                    return set + "/" + png
                }
            }
        }
        return nil
    }
}
