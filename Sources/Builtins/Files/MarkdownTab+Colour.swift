import AppKit
import DesignKit

/// A colour of the user's own on a canvas or motion page, beyond the design system's and the page's (Claude Design's
/// picker): Other Colour… opens the Mac's colour panel (hex, eyedropper, the user's own swatches); each colour in the
/// menu says how it reads against the element's ground; the last colours picked come first.
extension MarkdownTab {
    /// The last six colours picked by hand, newest first, kept while Kelp runs.
    private static var recent: [String] = []
    /// The colour panel's target for each tab that opened it.
    private static let picks = NSMapTable<MarkdownTab, ColourPick>.weakToStrongObjects()

    func recentColours(_ menu: NSMenu, _ key: String) {
        guard !Self.recent.isEmpty else { return }
        menu.addItem(.sectionHeader(title: String(localized: "Recent")))
        for hex in Self.recent {
            let item = menu.add(hex) { [weak self] in self?.setColour(key, hex) }
            if let colour = NSColor(css: hex) { item.show(Self.swatch(colour)) }
        }
        menu.addItem(.separator())
    }

    func otherColour(_ menu: NSMenu, _ key: String, against: NSColor) {
        menu.addItem(.separator())
        menu.add(String(localized: "Other Colour…")) { [weak self] in self?.pickColour(key) }
    }

    private func pickColour(_ key: String) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = false   // one hand edit when the pick is made, not one each step of a drag
        let pick = ColourPick()   // held by the tab, as the panel holds its target weakly
        pick.picked = { [weak self] colour in self?.setColour(key, Self.hex(colour)) }
        Self.picks.setObject(pick, forKey: self)
        panel.setTarget(pick)
        panel.setAction(#selector(ColourPick.picked(_:)))
        panel.orderFront(nil)
    }

    private func setColour(_ key: String, _ hex: String) {
        Self.recent = Array(([hex] + Self.recent.filter { $0 != hex }).prefix(6))
        runJS("window.kelpProps?.set(\(Self.js(key)), \(Self.js(hex)))")
    }

    static func hex(_ colour: NSColor) -> String {
        let c = colour.usingColorSpace(.sRGB) ?? colour
        let parts = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        return "#" + parts.map { String(format: "%02x", $0) }.joined()
    }

    /// How two colours read against each other (WCAG): 1 to 21.
    nonisolated static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let lum = { (c: NSColor) -> Double in
            let s = c.usingColorSpace(.sRGB) ?? c
            let v = [s.redComponent, s.greenComponent, s.blueComponent].map { Double($0) }.map {
                $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    nonisolated static func ratioText(_ ratio: Double) -> String {
        String(format: "%.1f:1", ratio) + (ratio < 4.5 ? " · " + String(localized: "too faint for text") : "")
    }
}

/// The colour panel's target: it answers the panel's action with the colour picked.
@MainActor
final class ColourPick: NSObject {
    var picked: ((NSColor) -> Void)?
    @objc func picked(_ panel: NSColorPanel) { picked?(panel.color) }
}
