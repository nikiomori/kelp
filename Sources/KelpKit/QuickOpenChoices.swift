import AppKit
import Core
import DesignKit

extension QuickOpen {
    /// What a setting can be set to: the values and their names.
    func choices(_ spec: SettingSpec) -> [(JSONValue, String)] {
        switch spec.type {
        case "boolean": return [(.bool(true), String(localized: "On")), (.bool(false), String(localized: "Off"))]
        case "number":
            return (spec.options ?? []).compactMap(Double.init).map { v -> (JSONValue, String) in
                let whole = v == v.rounded()
                return (whole ? .int(Int(v)) : .double(v), SettingRow.label(spec.key, whole ? String(Int(v)) : String(v), app))
            }
        default: return SettingRow.options(spec, app).map { (.string($0), SettingRow.label(spec.key, $0, app)) }
        }
    }

    /// A color theme's row: light or dark, and a tile of its colors (Match System shows both of its themes).
    func themeLook(_ id: String) -> (String, NSImage?) {
        let themes = app.themes.themes
        switch id {
        case "auto": return (String(localized: "Kelp Light or Dark, as macOS is"), Self.swatch(themes.filter { $0.id == "kelp.light" || $0.id == "kelp.dark" }))
        case "ghostty": return (String(localized: "The terminal keeps your Ghostty colors"), nil)
        default:
            guard let t = themes.first(where: { $0.id == id }) else { return ("", nil) }
            return (t.appearance == "light" ? String(localized: "Light") : String(localized: "Dark"), Self.swatch([t]))
        }
    }

    /// Themes side by side in an 18 pt tile: each its background with two lines of "text" in its foreground and blue.
    static func swatch(_ themes: [Theme]) -> NSImage {
        func color(_ hex: String?) -> NSColor { hex.flatMap { NSColor(hex: $0) } ?? .gray }
        return NSImage(size: NSSize(width: 18, height: 18), flipped: true) { r in
            let tile = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSGraphicsContext.saveGraphicsState(); tile.addClip()
            let w = r.width / CGFloat(max(themes.count, 1))
            for (i, t) in themes.enumerated() {
                let x = CGFloat(i) * w, c = t.terminal
                color(c?.background).setFill(); NSRect(x: x, y: 0, width: w, height: r.height).fill()
                color(c?.foreground).setFill(); NSRect(x: x + 3, y: 5, width: (w - 6) * 0.9, height: 2).fill()
                color(c?.palette?.dropFirst(4).first).setFill(); NSRect(x: x + 3, y: 10, width: (w - 6) * 0.6, height: 2).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.setStroke(); tile.stroke()
            return true
        }
    }
}
