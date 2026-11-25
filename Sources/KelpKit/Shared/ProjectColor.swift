import AppKit
import Core
import DesignKit

extension ProjectColor {
    var hue: IconTile.Hue { IconTile.Hue(dark: ink.dark, light: ink.light, gray: false) }

    /// The colour for text or a mark. It is at least 4.5:1 against the sidebar's window background in light mode, and
    /// 3.5–4.7:1 in dark mode, like the tiles' letters.
    package var color: NSColor { .dynamic(light: hue.ink(false), dark: hue.ink(true)) }

    /// One shade between the light and dark ones, for both appearances, because a view's shadow keeps the colour it
    /// was set with.
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

    /// The colour's dot, shown in the submenu.
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
}

/// How a project's colour shows (Appearance › Sidebar › Project color).
enum ProjectColorStyle: String {
    case icon, card
}

/// The colour settings that the views showing a project follow.
struct ProjectLook: Equatable {
    var style: ProjectColorStyle
    var colors: [String: ProjectColor]
}

extension Arrangement {
    var projectLook: ProjectLook {
        var colors = projectColors
        if let preview = colorPreview { colors[preview.project] = preview.color }
        return ProjectLook(
            style: ProjectColorStyle(rawValue: app.settings[SettingKeys.projectColor]) ?? .icon,
            colors: colors)
    }

    /// Returns the colour the icon of the project in this folder takes, wherever it shows. It has one only in the Icon
    /// style.
    func iconColor(folder: String) -> ProjectColor? {
        let look = projectLook
        guard look.style == .icon, let id = app.repos.first(where: { $0.path == folder })?.id else { return nil }
        return look.colors[id]
    }
}
