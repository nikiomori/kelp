// Who is at the page and what it does: the agent's colour on its pointer and glow, and a label at the pointer.
import AppKit
import Core
import DesignKit
import KelpKit

extension BrowserTab {
    /// The pointer's colour and label for `action` on `ref`, as the user watching reads it: the agent's own colour
    /// (Claude's orange), Kelp's purple for one whose colour doesn't stand out on a page (near black, grey), and
    /// `Claude · clicks “Save”`; plus the label's type size and padding.
    func pointerLook(_ action: BrowserAction, ref: String, _ request: JSONValue) -> [String: Any] {
        let agent = request["session"]?.string.flatMap { app.session($0) }?.agent
        let who = agent == nil ? String(localized: "Agent") : app.catalog.name(agent)
        let what = drive?.names[ref].flatMap(Self.shownName).map { " “\($0)”" } ?? ""
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

    /// `button "Save"` → `Save`: the name a snapshot gave, without its role; nil for an element without one.
    nonisolated static func shownName(_ named: String) -> String? {
        guard let open = named.firstIndex(of: "\""), let close = named.lastIndex(of: "\""), open < close else {
            return nil
        }
        return named[named.index(after: open)..<close].replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// A colour that stands out on any page: the agent's own, unless it's grey, nearly black or nearly white.
    static func vivid(_ hex: String?) -> NSColor {
        guard let color = hex.flatMap(NSColor.init(hex:))?.usingColorSpace(.sRGB), color.saturationComponent > 0.3,
            (0.35...0.95).contains(color.brightnessComponent)
        else { return .systemPurple }
        return color
    }
}
