import Foundation

/// Where a project keeps its own icon: where web, desktop, Android and Xcode projects keep theirs, at the top or in one of
/// its folders (a monorepo's `frontend/public/`, an app's `Resources/`, an Android module's `src/main/res/`). Looked for
/// the same way in a project here (`ProjectIcon`) and on a host (`repo.icon`).
public enum IconSearch {
    /// Where icons are kept, relative to the project or one of its top folders.
    public static let places = ["", "public/", "static/", "app/", "src/app/", "src/assets/", "assets/", "Assets/", "Resources/",
                                "img/", "images/", "icons/", "build/", "src-tauri/icons/", "docs/", ".github/",
                                "src/main/res/mipmap-xxxhdpi/", "src/main/res/mipmap-xxhdpi/"]
    /// What they're called, best first; any other `.icns`, then an Xcode AppIcon set, then an image named after the
    /// project come after these.
    public static let names = ["AppIcon.icns", "icon.icns", "apple-touch-icon.png", "favicon.svg", "icon.svg", "icon.png",
                               "favicon.png", "favicon.ico", "ic_launcher.png", "ic_launcher.webp", "logo.svg", "logo.png"]
    static let imageTypes: Set = ["svg", "png", "ico", "icns", "webp"]

    /// The project's own places first, then each top folder's. A bounded look. `name` is the project's (its folder's by
    /// default), `list` gives a folder's names (nil: no such folder) and `size` a file's bytes: this Mac's, unless
    /// they're a host's listing.
    public static func find(in repo: String, name: String? = nil,
                            list: (String) -> [String]? = { try? FileManager.default.contentsOfDirectory(atPath: $0) },
                            size: (String) -> Int = { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int) ?? 0 }) -> String? {
        let words = (name ?? (repo as NSString).lastPathComponent).lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
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
            // A site's favicon under its own name (`pretype-icon.svg`), never another brand's (`github-icon.svg`).
            for kind in ["icon", "logo"] {
                for (dir, files) in dirs {
                    if let f = files.sorted().first(where: { ownImage($0, kind, words) }) { return dir + f }
                }
            }
        }
        return nil
    }

    private static func ownImage(_ file: String, _ kind: String, _ words: [String]) -> Bool {
        let f = file.lowercased()
        return f.contains(kind) && imageTypes.contains((f as NSString).pathExtension) && words.contains { f.contains($0) }
    }
}
