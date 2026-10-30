import AppKit
import Core
import DesignKit

/// The colours a project can be given in its row's menu: `IconTile`'s own hues and two more, none of them orange or red,
/// which beside a row's marks mean asking and failed. Kept by name in UIState; one a later build dropped reads as none.
enum ProjectColor: String, CaseIterable {
    case blue, indigo, purple, pink, teal, yellow, brown

    static let key = "sidebar.colors"

    var hue: IconTile.Hue {
        switch self {
        case .blue: IconTile.Hue(dark: 0x6CB4FF, light: 0x0058B8, gray: false)
        case .indigo: IconTile.Hue(dark: 0x9E9CFF, light: 0x4440C0, gray: false)
        case .purple: IconTile.Hue(dark: 0xD59CFF, light: 0x8A2BB0, gray: false)
        case .pink: IconTile.Hue(dark: 0xF49AC1, light: 0xA8246A, gray: false)
        case .teal: IconTile.Hue(dark: 0x5BD6E6, light: 0x006473, gray: false)
        case .yellow: IconTile.Hue(dark: 0xE6C75A, light: 0x6E5400, gray: false)
        case .brown: IconTile.Hue(dark: 0xD2AE88, light: 0x7A5230, gray: false)
        }
    }

    /// As text or a mark: ≥ 4.5:1 on the sidebar's window ground in light, 3.5–4.7:1 in dark, as the tiles' letters are.
    var color: NSColor { .dynamic(light: hue.ink(false), dark: hue.ink(true)) }

    /// One shade for both appearances, between the two: a view's shadow keeps the colour it was set with.
    var glow: NSColor { hue.ink(true).blended(withFraction: 0.5, of: hue.ink(false)) ?? hue.ink(true) }

    var title: String {
        switch self {
        case .blue: String(localized: "Blue")
        case .indigo: String(localized: "Indigo")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .teal: String(localized: "Teal")
        case .yellow: String(localized: "Yellow")
        case .brown: String(localized: "Brown")
        }
    }

    /// Its dot, beside a project's name and in the submenu.
    var dot: NSImage {
        let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { [color] r in
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
            return true
        }
        img.cacheMode = .never   // drawn again for each appearance
        img.accessibilityDescription = title
        return img
    }

    /// As `uiState` keeps them: id → name.
    static func value(_ colors: [String: ProjectColor]) -> JSONValue { .object(colors.mapValues { .string($0.rawValue) }) }
    static func read(_ v: JSONValue?) -> [String: ProjectColor] {
        guard case .object(let o)? = v else { return [:] }
        return o.compactMapValues { $0.string.flatMap(ProjectColor.init) }
    }
}

/// How a project's colour shows (Appearance › Sidebar › Project color).
enum ProjectColorStyle: String {
    case icon, dot, glow, name, card

    /// Drawn on the project's card: a project with nothing under it gets one, once it has a colour.
    var onCard: Bool { self == .glow || self == .card }
}

/// What the views showing a project follow.
struct ProjectLook: Equatable {
    var style: ProjectColorStyle
    var colors: [String: ProjectColor]
}

extension AppModel {
    var projectLook: ProjectLook {
        var colors = projectColors
        if let p = colorPreview { colors[p.project] = p.color }
        return ProjectLook(style: ProjectColorStyle(rawValue: settings.string("workbench.sidebar.projectColor") ?? "") ?? .icon, colors: colors)
    }

    /// The colour the icon of the project in this folder takes, wherever it shows: only in the Icon style.
    func iconColor(folder: String) -> ProjectColor? {
        let look = projectLook
        guard look.style == .icon, let id = repos.first(where: { $0.path == folder })?.id else { return nil }
        return look.colors[id]
    }
}
