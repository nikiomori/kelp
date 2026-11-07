import Foundation

/// The subset of a Ghostty config Kelp honours: colors and font.
public struct GhosttyConfig: Equatable, Sendable {
    public var background: String?, foreground: String?, fontFamily: String?, fontSize: Double?
    public var palette: [Int: String] = [:]

    public static func parse(_ text: String) -> GhosttyConfig {
        var c = GhosttyConfig()
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            switch k {
            case "background": c.background = v
            case "foreground": c.foreground = v
            case "font-family": if c.fontFamily == nil { c.fontFamily = v }
            case "font-size": c.fontSize = Double(v)
            case "palette":   // palette = 1=#ff0000
                let p = v.split(separator: "=", maxSplits: 1)
                if p.count == 2, let i = Int(p[0]) { c.palette[i] = String(p[1]) }
            default: break
            }
        }
        return c
    }

    public static func load() -> GhosttyConfig? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for p in [".config/ghostty/config", "Library/Application Support/com.mitchellh.ghostty/config"] {
            if let t = try? String(contentsOf: home.appendingPathComponent(p), encoding: .utf8) { return parse(t) }
        }
        return nil
    }

    /// "#1e1e2e" / "1e1e2e" -> (r, g, b) in 0...1
    public static func rgb(_ hex: String) -> (Double, Double, Double)? {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return (Double(v >> 16 & 0xff) / 255, Double(v >> 8 & 0xff) / 255, Double(v & 0xff) / 255)
    }
}
