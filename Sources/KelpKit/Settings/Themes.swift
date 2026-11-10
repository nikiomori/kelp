import AppKit
import Core
import DesignKit
import EditorKit
import Observation
import SwiftUI
import TerminalKit

/// A color theme: terminal and editor colors, optionally tied to light or dark appearance, and how the window around them
/// is built (docs/extensions.md).
struct Theme: Codable, Identifiable, Equatable {
    struct TerminalColors: Codable, Equatable {
        var background: String, foreground: String
        var cursor: String?, selection: String?
        var palette: [String]?
        var opacity: Double?, shader: String?
    }
    struct EditorColors: Codable, Equatable {
        var background: String, text: String
        var keyword: String?, string: String?, comment: String?, type: String?, number: String?, function: String?
        var selection: String?, lineHighlight: String?
        var opacity: Double?
    }
    /// The panels and the gap round the editor area ("surface"), the editor area ("card") and the chrome's accent and face.
    /// A theme without one gets a window in its own colours.
    struct Window: Codable, Equatable {
        var surface: String?   // a colour, or "material": macOS's own, the desktop showing through
        var surfaceOpacity: Double?
        var card: String?, border: String?
        var borderWidth: Double?, radius: Double?
        var accent: String?
        var font: String?   // "mono", "serif", "rounded"
        var ambient: String?   // "aurora", "motes", "grid"
        var ambientColors: [String]?
    }
    /// A colour for the terminal's config file, which is read line by line. A theme is someone else's, and more than one word
    /// could add a line of its own there ("#000\nkeybind = …") past the review that says it runs no commands.
    static func terminalColor(_ value: String?) -> String? {
        value.flatMap { $0.range(of: #"\A#?[0-9A-Za-z]+\z"#, options: .regularExpression) == nil ? nil : $0 }
    }

    var id: String
    var name: String
    var appearance: String?   // "light" / "dark" / nil (either)
    var terminal: TerminalColors?
    var editor: EditorColors?
    var window: Window?
}

/// The window as the chosen theme has it; nil is the system's.
struct WindowLook: Equatable {
    struct Ambient: Equatable {
        enum Kind: String { case aurora, motes, grid }
        var kind: Kind, colors: [NSColor]
    }
    var surface: NSColor?, card: NSColor?, border: NSColor?
    var borderWidth: CGFloat = 1, radius = Metrics.radiusLG
    var ambient: Ambient?
    /// The terminals show what's under them.
    var seeThrough = false
    /// A surface nothing shows through: macOS needn't blur the desktop for it, on every frame of a moving backdrop too.
    var solid: Bool { surface?.alphaComponent == 1 }
}

/// Applies the chosen theme and fonts to the window, terminals and editors whenever settings change.
@MainActor
@Observable
package final class ThemeManager {
    @ObservationIgnored let app: AppModel
    init(app: AppModel) { self.app = app }
    @ObservationIgnored private var lastTerminal: TerminalAppearance?
    @ObservationIgnored private var appearanceObserver: NSKeyValueObservation?
    /// Counts the changes of the editors' look (`CodeEditor.apply(look:)`, which Observation can't see), for code shown
    /// outside an editor in it (a diff, a page's preview): the editors themselves follow on their own.
    private(set) package var editorRevision = 0
    private(set) var look = WindowLook()
    /// The chrome's text, what panels rebuild for: its size and the theme's face.
    private(set) var chromeText = " "
    private(set) package var chromeDesign = Font.Design.default

    static let builtin: [Theme] = [
        Theme(
            id: "kelp.light", name: "Kelp Light", appearance: "light",
            terminal: .init(
                background: "#ffffff", foreground: "#1d1d1f", cursor: nil, selection: "#b3d7ff",
                palette: [
                    "#1d1d1f", "#c41a16", "#007400", "#826b28", "#0b4f79", "#9b2393", "#326d74", "#8e8e93",
                    "#636366", "#e0362e", "#28a745", "#b28600", "#0a84ff", "#bf5af2", "#3a9bae", "#1d1d1f"
                ]),
            editor: nil, window: .system),
        Theme(
            id: "kelp.dark", name: "Kelp Dark", appearance: "dark",
            terminal: .init(
                background: "#1e1e22", foreground: "#e5e5ea", cursor: nil, selection: "#3a4a63",
                palette: [
                    "#2c2c30", "#ff6b6b", "#7ee787", "#e3c26a", "#6cb6ff", "#d2a8ff", "#5dd8e0", "#c7c7cc",
                    "#636366", "#ff8a80", "#97f3a0", "#f2d58a", "#8cc8ff", "#e0bfff", "#87e5ec", "#ffffff"
                ]),
            editor: .init(
                background: "#1e1e22", text: "#e5e5ea", keyword: "#ff7ab2", string: "#ff8170", comment: "#7f8c98",
                type: "#5dd8ff", number: "#d9c97c", function: "#67b7a4"), window: .system),
        Theme(
            id: "kelp.black", name: "Kelp Black", appearance: "dark",
            terminal: .init(
                background: "#000000", foreground: "#e5e5ea", cursor: nil, selection: "#2a3a55",
                palette: [
                    "#1c1c1e", "#ff6b6b", "#7ee787", "#e3c26a", "#6cb6ff", "#d2a8ff", "#5dd8e0", "#c7c7cc",
                    "#636366", "#ff8a80", "#97f3a0", "#f2d58a", "#8cc8ff", "#e0bfff", "#87e5ec", "#ffffff"
                ]),
            editor: .init(
                background: "#000000", text: "#e5e5ea", keyword: "#ff7ab2", string: "#ff8170", comment: "#7f8c98",
                type: "#5dd8ff", number: "#d9c97c", function: "#67b7a4"), window: .system)
    ]

    /// "auto" follows macOS light/dark; "ghostty" leaves the terminal to ~/.config/ghostty.
    var themes: [Theme] { Self.builtin + Theme.looks + Theme.popular + app.extensions.all.themes }

    /// What terminals are painted with now (Ghostty's own config when the theme leaves it to Ghostty).
    var terminalBackground: NSColor {
        let hex =
            lastTerminal?.background
            ?? (lastTerminal?.useGhosttyConfig != false ? GhosttyConfig.load()?.background : nil)
        return hex.flatMap { NSColor(hex: $0) } ?? .textBackgroundColor
    }

    /// The theme painting the window now: Match System's light or dark one; nil for Ghostty's own colors.
    var shown: Theme? {
        let id = app.settings[SettingKeys.theme]
        return id == "ghostty"
            ? nil : themes.first { $0.id == (id == "auto" ? (isDark ? "kelp.dark" : "kelp.light") : id) }
    }

    /// A font setting's family; nil: empty, the theme's or the system's.
    private static func named(_ family: String) -> String? { family.isEmpty ? nil : family }

    var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    func apply() {
        let settings = app.settings
        // One choice, like VS Code: a theme with its own look (Kelp Light, Dracula…) sets the whole window's;
        // Match System and Ghostty follow macOS.
        let want: NSAppearance.Name? =
            switch themes.first(where: { $0.id == settings[SettingKeys.theme] })?.appearance {
            case "light": .aqua
            case "dark": .darkAqua
            default: nil
            }
        if NSApp.appearance?.name != want { NSApp.appearance = want.flatMap { NSAppearance(named: $0) } }
        if appearanceObserver == nil {
            // macOS switched light/dark: "auto" themes follow (colors only; setting the appearance here would loop).
            appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyColors() }
            }
        }
        applyColors()
    }

    func applyColors() {
        let settings = app.settings
        let theme = shown

        var terminal = TerminalAppearance()
        terminal.useGhosttyConfig = theme == nil || settings[SettingKeys.useGhosttyConfig]
        if let colors = theme?.terminal {
            terminal.background = Theme.terminalColor(colors.background)
            terminal.foreground = Theme.terminalColor(colors.foreground)
            // the system's accent, by name
            terminal.cursor = Theme.terminalColor(colors.cursor) ?? NSColor.controlAccentColor.hexString
            terminal.selection = Theme.terminalColor(colors.selection)
            terminal.palette = (colors.palette ?? []).compactMap(Theme.terminalColor)
        }
        terminal.fontFamily = Self.named(settings[SettingKeys.terminalFontFamily])
        terminal.fontSize = settings[SettingKeys.terminalFontSize]
        terminal.cursorStyle = settings[SettingKeys.cursorStyle]
        terminal.optionAsAlt = settings[SettingKeys.optionAsAlt]
        // Settings › Appearance › Terminal opacity, over any theme: the window opens up with it.
        let opacity = Double(settings[SettingKeys.terminalOpacity]).map { $0 / 100 }
        terminal.opacity = opacity ?? theme?.terminal?.opacity
        terminal.shader = theme?.terminal?.shader
        lastTerminal = terminal
        GhosttyRuntime.apply(terminal, cleanCopy: settings[SettingKeys.cleanCopy])

        let editor = theme?.editor
        let palette = editor.map {
            CodeEditor.Palette(
                background: $0.background + Self.alpha($0.opacity), text: $0.text,
                keyword: $0.keyword, string: $0.string, comment: $0.comment, type: $0.type,
                number: $0.number, function: $0.function, selection: $0.selection ?? theme?.terminal?.selection,
                lineHighlight: $0.lineHighlight)
        }
        let size = CGFloat(settings[SettingKeys.editorFontSize])
        let font = Self.named(settings[SettingKeys.editorFontFamily])
        let wrap = settings[SettingKeys.wordWrap]
        let hang = CodeEditor.WrappingIndent(rawValue: settings[SettingKeys.wrappingIndent]) ?? .same
        TextSize.apply(settings[SettingKeys.textSize])
        TextSize.apply(design: theme?.window?.font)
        chromeText = "\(settings[SettingKeys.textSize]) \(theme?.window?.font ?? "")"
        chromeDesign =
            ["mono": .monospaced, "serif": .serif, "rounded": .rounded][theme?.window?.font ?? ""] ?? .default
        NSColor.setThemeAccent(Self.accent(theme))
        look = Self.windowLook(theme, terminalOpacity: terminal.opacity ?? 1, forced: opacity)
        // Read by Foundation at launch, so a change shows the next time Kelp opens.
        let chosen = settings[SettingKeys.language], language = chosen == "system" ? nil : [chosen]
        UserDefaults.standard.set(language, forKey: "AppleLanguages")
        // Every editor follows at once; the revision is for what shows code outside one (a diff, a page's preview).
        let code = CodeEditor.Look(
            palette: palette, fontSize: size, fontName: font, wrapLines: wrap, wrappingIndent: hang)
        if CodeEditor.apply(look: code) { editorRevision += 1 }
    }

    /// "#rrggbb" takes two more digits for alpha.
    private static func alpha(_ opacity: Double?) -> String {
        opacity.map { String(format: "%02x", Int(($0 * 255).rounded())) } ?? ""
    }

    private static func accent(_ theme: Theme?) -> NSColor? {
        if let window = theme?.window { return window.accent.flatMap { NSColor(hex: $0) } }
        return theme?.terminal?.palette.flatMap { $0.count > 4 ? NSColor(hex: $0[4]) : nil }   // ANSI blue, as near as a palette has to one
    }

    /// `forced`: the terminal's opacity from Settings, which opens up a theme that doesn't.
    static func windowLook(_ theme: Theme?, terminalOpacity: Double, forced: Double?) -> WindowLook {
        guard let theme, let background = theme.terminal.flatMap({ NSColor(hex: $0.background) }) else {
            return terminalOpacity < 1 ? WindowLook(card: .clear, seeThrough: true) : WindowLook()
        }
        var look = WindowLook(), window = theme.window ?? Theme.Window.own(theme)
        look.seeThrough = terminalOpacity < 1
        if let forced, forced < 1 { window.surfaceOpacity = min(window.surfaceOpacity ?? 1, forced) }
        if window.surface != "material" {
            let surface = window.surface.flatMap { NSColor(hex: $0) } ?? background
            look.surface = surface.withAlphaComponent(window.surfaceOpacity ?? 1)
        }
        look.card =
            look.seeThrough
            ? .clear : window.card.flatMap { NSColor(hex: $0) } ?? (window.surface == "material" ? nil : background)
        look.border = window.border.flatMap { NSColor(hex: $0) }
        look.borderWidth = window.borderWidth ?? 1
        look.radius = window.radius ?? Metrics.radiusLG
        if let kind = window.ambient.flatMap(WindowLook.Ambient.Kind.init) {
            look.ambient = .init(kind: kind, colors: (window.ambientColors ?? []).compactMap { NSColor(hex: $0) })
        }
        return look
    }
}

extension Theme.Window {
    /// A window in the theme's colours: the card its background, the surface round it a shade further from its text.
    static func own(_ theme: Theme) -> Self {
        let dark = theme.appearance != "light"
        let shade = (theme.terminal?.background).flatMap { NSColor(hex: $0) }?.blended(
            withFraction: dark ? 0.18 : 0.04, of: .black)
        return Self(surface: shade?.hexString, card: theme.terminal?.background)
    }
    /// macOS's own window: the Kelp themes'.
    static let system = Self(surface: "material")
}
