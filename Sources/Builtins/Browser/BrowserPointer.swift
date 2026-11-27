// Shows who is at the page and what it does, with the agent's colour on its pointer and glow, and a label at the
// pointer.
import AppKit
import Core
import DesignKit
import KelpKit

extension BrowserTab {
    /// Returns the pointer's colour and label for `action` on `ref`, as the user watching sees them. The colour is the
    /// agent's own (Claude's orange), or Kelp's purple for an agent whose colour doesn't stand out on a page (near
    /// black, grey). The label reads like `Claude · clicks “Save”`, and its type size and padding come with it.
    func pointerLook(_ action: BrowserAction, ref: String, _ request: JSONValue) -> [String: Any] {
        let agent = request["session"]?.string.flatMap { app.session($0) }?.agent
        let who = agent == nil ? String(localized: "Agent") : app.catalog.name(agent)
        let what = (drive?.names[ref]?.name).flatMap(Self.shownName).map { " “\($0)”" } ?? ""
        return [
            "accent": Self.vivid(app.catalog.color(agent)).hexString, "label": "\(who) · \(Self.verb(action))\(what)",
            "font": TextSize.of(TextSize.row), "padX": Metrics.gap, "padY": Metrics.lineGap
        ]
    }

    nonisolated static func verb(_ action: BrowserAction) -> String {
        switch action {
        case .type: String(localized: "types in")
        case .hover: String(localized: "points at")
        case .drag: String(localized: "drags")
        case .upload: String(localized: "adds files to")
        default: String(localized: "clicks")
        }
    }

    /// Returns the name a snapshot gave an element, without its role, so `button "Save"` gives `Save`. It returns nil
    /// for an element without a name.
    nonisolated static func shownName(_ named: String) -> String? {
        guard let open = named.firstIndex(of: "\""), let close = named.lastIndex(of: "\""), open < close else {
            return nil
        }
        return named[named.index(after: open)..<close].replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Returns a colour that stands out on any page: the agent's own, unless it's grey, nearly black or nearly white.
    static func vivid(_ hex: String?) -> NSColor {
        guard let color = hex.flatMap(NSColor.init(hex:))?.usingColorSpace(.sRGB), color.saturationComponent > 0.3,
            (0.35...0.95).contains(color.brightnessComponent)
        else { return .systemPurple }
        return color
    }
}
