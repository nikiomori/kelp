import AppKit
import Observation
import SwiftUI
import Core
import DesignKit
import TerminalKit
import EditorKit

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
        var surface: String?     // a colour, or "material": macOS's own, the desktop showing through
        var surfaceOpacity: Double?
        var card: String?, border: String?
        var borderWidth: Double?, radius: Double?
        var accent: String?
        var font: String?        // "mono", "serif", "rounded"
        var ambient: String?     // "aurora", "motes", "grid"
        var ambientColors: [String]?
    }
    var id: String
    var name: String
    var appearance: String?      // "light" / "dark" / nil (either)
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
    /// Editors' colors and font live in CodeEditor's statics, which Observation can't see: this counts their changes,
    /// and open editors follow it.
    private(set) package var editorRevision = 0
    private(set) var look = WindowLook()
    /// The chrome's text, what panels rebuild for: its size and the theme's face.
    private(set) package var chromeText = " "
    private(set) var chromeDesign = Font.Design.default

    static let builtin: [Theme] = [
        Theme(id: "kelp.light", name: "Kelp Light", appearance: "light",
              terminal: .init(background: "#ffffff", foreground: "#1d1d1f", cursor: nil, selection: "#b3d7ff",
                              palette: ["#1d1d1f", "#c41a16", "#007400", "#826b28", "#0b4f79", "#9b2393", "#326d74", "#8e8e93",
                                        "#636366", "#e0362e", "#28a745", "#b28600", "#0a84ff", "#bf5af2", "#3a9bae", "#1d1d1f"]),
              editor: nil, window: .system),
        Theme(id: "kelp.dark", name: "Kelp Dark", appearance: "dark",
              terminal: .init(background: "#1e1e22", foreground: "#e5e5ea", cursor: nil, selection: "#3a4a63",
                              palette: ["#2c2c30", "#ff6b6b", "#7ee787", "#e3c26a", "#6cb6ff", "#d2a8ff", "#5dd8e0", "#c7c7cc",
                                        "#636366", "#ff8a80", "#97f3a0", "#f2d58a", "#8cc8ff", "#e0bfff", "#87e5ec", "#ffffff"]),
              editor: .init(background: "#1e1e22", text: "#e5e5ea", keyword: "#ff7ab2", string: "#ff8170", comment: "#7f8c98",
                            type: "#5dd8ff", number: "#d9c97c", function: "#67b7a4"), window: .system),
        Theme(id: "kelp.black", name: "Kelp Black", appearance: "dark",
              terminal: .init(background: "#000000", foreground: "#e5e5ea", cursor: nil, selection: "#2a3a55",
                              palette: ["#1c1c1e", "#ff6b6b", "#7ee787", "#e3c26a", "#6cb6ff", "#d2a8ff", "#5dd8e0", "#c7c7cc",
                                        "#636366", "#ff8a80", "#97f3a0", "#f2d58a", "#8cc8ff", "#e0bfff", "#87e5ec", "#ffffff"]),
              editor: .init(background: "#000000", text: "#e5e5ea", keyword: "#ff7ab2", string: "#ff8170", comment: "#7f8c98",
                            type: "#5dd8ff", number: "#d9c97c", function: "#67b7a4"), window: .system)
    ]

    /// "auto" follows macOS light/dark; "ghostty" leaves the terminal to ~/.config/ghostty.
    var themes: [Theme] { Self.builtin + Theme.looks + Theme.popular + app.extensions.all.themes }

    /// What terminals are painted with now (Ghostty's own config when the theme leaves it to Ghostty).
    var terminalBackground: NSColor {
        let hex = lastTerminal?.background ?? (lastTerminal?.useGhosttyConfig != false ? GhosttyConfig.load()?.background : nil)
        return hex.flatMap { NSColor(hex: $0) } ?? .textBackgroundColor
    }

    var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    func apply() {
        let s = app.settings
        // One choice, like VS Code: a theme with its own look (Kelp Light, Dracula…) sets the whole window's;
        // Match System and Ghostty follow macOS.
        let want: NSAppearance.Name? = switch themes.first(where: { $0.id == s.string("workbench.theme") })?.appearance {
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
        let s = app.settings
        let id = s.string("workbench.theme") ?? "auto"
        let theme: Theme? = id == "ghostty" ? nil : themes.first { $0.id == (id == "auto" ? (isDark ? "kelp.dark" : "kelp.light") : id) }

        var t = TerminalAppearance()
        t.useGhosttyConfig = theme == nil || s.bool("terminal.useGhosttyConfig") == true
        if let c = theme?.terminal {
            t.background = c.background
            t.foreground = c.foreground
            t.cursor = c.cursor ?? NSColor.controlAccentColor.hexString   // the system's accent, by name
            t.selection = c.selection
            t.palette = c.palette ?? []
        }
        t.fontFamily = s.string("terminal.fontFamily").flatMap { $0.isEmpty ? nil : $0 }
        t.fontSize = s.number("terminal.fontSize")
        t.cursorStyle = s.string("terminal.cursorStyle")
        t.optionAsAlt = s.bool("terminal.optionAsAlt") ?? false
        // Settings › Appearance › Terminal opacity, over any theme: the window opens up with it.
        let opacity = s.string("terminal.opacity").flatMap(Double.init).map { $0 / 100 }
        t.opacity = opacity ?? theme?.terminal?.opacity
        t.shader = theme?.terminal?.shader
        GhosttyRuntime.cleanCopy = s.bool("terminal.cleanCopy") ?? true
        if t != lastTerminal {
            lastTerminal = t
            GhosttyRuntime.appearance = t
            if GhosttyTerminalView.isLoaded { GhosttyRuntime.shared.configure(t) }
        }

        let e = theme?.editor
        let palette = e.map { CodeEditor.Palette(background: $0.background + Self.alpha($0.opacity), text: $0.text,
                                                 keyword: $0.keyword, string: $0.string, comment: $0.comment, type: $0.type,
                                                 number: $0.number, function: $0.function, selection: $0.selection ?? theme?.terminal?.selection,
                                                 lineHighlight: $0.lineHighlight) }
        let size = CGFloat(s.number("editor.fontSize") ?? 13), font = s.string("editor.fontFamily").flatMap { $0.isEmpty ? nil : $0 }
        let wrap = s.bool("editor.wordWrap") ?? false
        TextSize.apply(s.string("workbench.textSize"))
        TextSize.apply(design: theme?.window?.font)
        chromeText = "\(s.string("workbench.textSize") ?? "") \(theme?.window?.font ?? "")"
        chromeDesign = ["mono": .monospaced, "serif": .serif, "rounded": .rounded][theme?.window?.font ?? ""] ?? .default
        NSColor.setThemeAccent(Self.accent(theme))
        look = Self.windowLook(theme, terminalOpacity: t.opacity ?? 1, forced: opacity)
        // Read by Foundation at launch, so a change shows the next time Kelp opens.
        let language = s.string("workbench.language").flatMap { $0 == "system" ? nil : [$0] }
        UserDefaults.standard.set(language, forKey: "AppleLanguages")
        if palette != CodeEditor.palette || size != CodeEditor.fontSize || font != CodeEditor.fontName || wrap != CodeEditor.wrapLines {
            CodeEditor.palette = palette
            CodeEditor.fontSize = size
            CodeEditor.fontName = font
            CodeEditor.wrapLines = wrap
            editorRevision += 1
        }
    }

    /// "#rrggbb" takes two more digits for alpha.
    private static func alpha(_ opacity: Double?) -> String {
        opacity.map { String(format: "%02x", Int(($0 * 255).rounded())) } ?? ""
    }

    private static func accent(_ theme: Theme?) -> NSColor? {
        if let w = theme?.window { return w.accent.flatMap { NSColor(hex: $0) } }
        return theme?.terminal?.palette.flatMap { $0.count > 4 ? NSColor(hex: $0[4]) : nil }   // ANSI blue, as near as a palette has to one
    }

    /// `forced`: the terminal's opacity from Settings, which opens up a theme that doesn't.
    static func windowLook(_ theme: Theme?, terminalOpacity: Double, forced: Double?) -> WindowLook {
        guard let theme, let background = theme.terminal.flatMap({ NSColor(hex: $0.background) }) else {
            return terminalOpacity < 1 ? WindowLook(card: .clear, seeThrough: true) : WindowLook()
        }
        var l = WindowLook(), w = theme.window ?? Theme.Window.own(theme)
        l.seeThrough = terminalOpacity < 1
        if let forced, forced < 1 { w.surfaceOpacity = min(w.surfaceOpacity ?? 1, forced) }
        if w.surface != "material" {
            let surface = w.surface.flatMap { NSColor(hex: $0) } ?? background
            l.surface = surface.withAlphaComponent(w.surfaceOpacity ?? 1)
        }
        l.card = l.seeThrough ? .clear : w.card.flatMap { NSColor(hex: $0) } ?? (w.surface == "material" ? nil : background)
        l.border = w.border.flatMap { NSColor(hex: $0) }
        l.borderWidth = w.borderWidth ?? 1
        l.radius = w.radius ?? Metrics.radiusLG
        if let kind = w.ambient.flatMap(WindowLook.Ambient.Kind.init) {
            l.ambient = .init(kind: kind, colors: (w.ambientColors ?? []).compactMap { NSColor(hex: $0) })
        }
        return l
    }
}

extension Theme.Window {
    /// A window in the theme's colours: the card its background, the surface round it a shade further from its text.
    static func own(_ theme: Theme) -> Self {
        let dark = theme.appearance != "light"
        let shade = (theme.terminal?.background).flatMap { NSColor(hex: $0) }?.blended(withFraction: dark ? 0.18 : 0.04, of: .black)
        return Self(surface: shade?.hexString, card: theme.terminal?.background)
    }
    /// macOS's own window: the Kelp themes'.
    static let system = Self(surface: "material")
}
