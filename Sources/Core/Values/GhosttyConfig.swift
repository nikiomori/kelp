import Foundation

/// The subset of a Ghostty config Kelp honours: colors and font.
public struct GhosttyConfig: Equatable, Sendable {
    public var background: String?, foreground: String?, fontFamily: String?, fontSize: Double?
    public var palette: [Int: String] = [:]

    public static func parse(_ text: String) -> GhosttyConfig {
        var config = GhosttyConfig()
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "background": config.background = value
            case "foreground": config.foreground = value
            case "font-family": if config.fontFamily == nil { config.fontFamily = value }
            case "font-size": config.fontSize = Double(value)
            case "palette":   // A line like palette = 1=#ff0000
                let pair = value.split(separator: "=", maxSplits: 1)
                if pair.count == 2, let index = Int(pair[0]) { config.palette[index] = String(pair[1]) }
            default: break
            }
        }
        return config
    }

    public static func load() -> GhosttyConfig? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in [".config/ghostty/config", "Library/Application Support/com.mitchellh.ghostty/config"] {
            if let text = String(contentsIfAny: home.appendingPathComponent(path)) {
                return parse(text)
            }
        }
        return nil
    }
}
