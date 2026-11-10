import Foundation

/// The Android SDK an Android machine runs from: the user's own (Android Studio's), found by ANDROID_HOME,
/// ANDROID_SDK_ROOT or its usual place. Kelp downloads none of it.
public enum AndroidSDK {
    public static var root: URL? {
        let env = ProcessInfo.processInfo.environment
        let candidates =
            [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"]].compactMap { $0 }
            + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk").path]
        return candidates.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("emulator/emulator").path) }
    }
    public static var adb: String? { root.map { $0.appendingPathComponent("platform-tools/adb").path } }
    public static var emulator: String? { root.map { $0.appendingPathComponent("emulator/emulator").path } }
    public static var avdmanager: String? {
        root.map { $0.appendingPathComponent("cmdline-tools/latest/bin/avdmanager").path }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    /// The newest arm64 system image installed: "system-images;android-36.1;google_apis_playstore;arm64-v8a".
    public static func newestImage() -> String? {
        guard let dir = root?.appendingPathComponent("system-images") else { return nil }
        func names(_ folder: URL) -> [String] {   // one level, not the images' files
            do { return try FileManager.default.contentsOfDirectory(atPath: folder.path) } catch { return [] }
        }
        let apis = names(dir)
        func api(_ name: String) -> Double { Double(name.replacingOccurrences(of: "android-", with: "")) ?? 0 }
        for level in apis.sorted(by: { api($0) > api($1) }) {
            let tags = names(dir.appendingPathComponent(level))
            // The plain images are lighter than Play Store's (no Google services updating themselves at every boot).
            for tag in tags.sorted(by: { rank($0) < rank($1) })
            where FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(level)/\(tag)/arm64-v8a").path) {
                return "system-images;\(level);\(tag);arm64-v8a"
            }
        }
        return nil
    }
    private static func rank(_ tag: String) -> Int {
        ["default": 0, "google_apis": 1, "google_apis_playstore": 2][tag] ?? 3
    }

    /// What an app's screen holds, from `uiautomator dump`: a line each for the controls worth naming, indented by depth,
    /// with a ref to press and where it is: `- button "Sign in" [ref=e3] (96,1180 888×132)`. `centers` by ref, for taps.
    public static func ui(_ xml: String) -> (text: String, centers: [String: (x: Int, y: Int)]) {
        let reader = UIReader()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = reader
        parser.parse()
        return (reader.lines.joined(separator: "\n"), reader.centers)
    }

    private final class UIReader: NSObject, XMLParserDelegate {
        var lines: [String] = [], centers: [String: (x: Int, y: Int)] = [:]
        private var shown: [Bool] = []
        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            guard name == "node" else { return }
            let label = [attributes["text"], attributes["content-desc"]].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            let acts = ["clickable", "checkable", "scrollable", "long-clickable"].contains { attributes[$0] == "true" }
            let role = (attributes["class"] ?? "").split(separator: ".").last.map { $0.lowercased() } ?? "view"
            let show = !label.isEmpty || acts || role == "edittext"
            if show, let box = Self.bounds(attributes["bounds"]) {
                let ref = "e\(centers.count + 1)"
                centers[ref] = ((box.0 + box.2) / 2, (box.1 + box.3) / 2)
                let depth = shown.filter { $0 }.count
                let id =
                    (attributes["resource-id"].flatMap {
                        $0.isEmpty ? nil : $0.split(separator: "/").last.map(String.init)
                    }).map { " #\($0)" } ?? ""
                lines.append(
                    String(repeating: "  ", count: depth)
                        + "- \(role) \"\(label)\"\(id) [ref=\(ref)] "
                        + "(\(box.0),\(box.1) \(box.2 - box.0)×\(box.3 - box.1))"
                )
            }
            shown.append(show)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "node" { _ = shown.popLast() }
        }
        /// "[0,63][1080,210]" → (0, 63, 1080, 210).
        static func bounds(_ text: String?) -> (Int, Int, Int, Int)? {
            let numbers = (text ?? "").split(whereSeparator: { "[],".contains($0) }).compactMap { Int($0) }
            return numbers.count == 4 ? (numbers[0], numbers[1], numbers[2], numbers[3]) : nil
        }
    }

    /// `input text` takes no spaces or shell characters as they are: %s for a space, the rest escaped.
    public static func inputText(_ text: String) -> String {
        var out = ""
        for char in text {
            if char == " " {
                out += "%s"
            } else if "()<>|;&*\\~\"'`$".contains(char) {
                out += "\\\(char)"
            } else {
                out.append(char)
            }
        }
        return out
    }

    /// Key names agents use, as Android keycodes.
    public static let keys: [String: Int] = [
        "home": 3, "back": 4, "up": 19, "down": 20, "left": 21, "right": 22, "enter": 66, "return": 66, "tab": 61,
        "space": 62,
        "delete": 67, "backspace": 67, "escape": 111, "esc": 111, "menu": 82, "search": 84, "power": 26, "volumeup": 24,
        "volumedown": 25, "appswitch": 187, "recents": 187, "forwarddelete": 112
    ]
}
