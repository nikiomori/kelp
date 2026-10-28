import AppKit
import Observation
import Core
import DesignKit
import TerminalKit
import EditorKit

/// A color theme: terminal and editor colors, optionally tied to light or dark appearance.
struct Theme: Codable, Identifiable, Equatable {
    struct TerminalColors: Codable, Equatable {
        var background: String, foreground: String
        var cursor: String?, selection: String?
        var palette: [String]?
    }
    struct EditorColors: Codable, Equatable {
        var background: String, text: String
        var keyword: String?, string: String?, comment: String?, type: String?, number: String?, function: String?
        var selection: String?, lineHighlight: String?
    }
    var id: String
    var name: String
    var appearance: String?      // "light" / "dark" / nil (either)
    var terminal: TerminalColors?
    var editor: EditorColors?
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

    static let builtin: [Theme] = [
        Theme(id: "kelp.light", name: "Kelp Light", appearance: "light",
              terminal: .init(background: "#ffffff", foreground: "#1d1d1f", cursor: nil, selection: "#b3d7ff",
                              palette: ["#1d1d1f", "#c41a16", "#007400", "#826b28", "#0b4f79", "#9b2393", "#326d74", "#8e8e93",
                                        "#636366", "#e0362e", "#28a745", "#b28600", "#0a84ff", "#bf5af2", "#3a9bae", "#1d1d1f"]),
              editor: nil),
        Theme(id: "kelp.dark", name: "Kelp Dark", appearance: "dark",
              terminal: .init(background: "#1e1e22", foreground: "#e5e5ea", cursor: nil, selection: "#3a4a63",
                              palette: ["#2c2c30", "#ff6b6b", "#7ee787", "#e3c26a", "#6cb6ff", "#d2a8ff", "#5dd8e0", "#c7c7cc",
                                        "#636366", "#ff8a80", "#97f3a0", "#f2d58a", "#8cc8ff", "#e0bfff", "#87e5ec", "#ffffff"]),
              editor: .init(background: "#1e1e22", text: "#e5e5ea", keyword: "#ff7ab2", string: "#ff8170", comment: "#7f8c98",
                            type: "#5dd8ff", number: "#d9c97c", function: "#67b7a4")),
        Theme(id: "kelp.black", name: "Kelp Black", appearance: "dark",
              terminal: .init(background: "#000000", foreground: "#e5e5ea", cursor: nil, selection: "#2a3a55",
                              palette: ["#1c1c1e", "#ff6b6b", "#7ee787", "#e3c26a", "#6cb6ff", "#d2a8ff", "#5dd8e0", "#c7c7cc",
                                        "#636366", "#ff8a80", "#97f3a0", "#f2d58a", "#8cc8ff", "#e0bfff", "#87e5ec", "#ffffff"]),
              editor: .init(background: "#000000", text: "#e5e5ea", keyword: "#ff7ab2", string: "#ff8170", comment: "#7f8c98",
                            type: "#5dd8ff", number: "#d9c97c", function: "#67b7a4")),
        Theme(id: "dracula", name: "Dracula", appearance: "dark",
              terminal: .init(background: "#282a36", foreground: "#f8f8f2", cursor: "#f8f8f2", selection: "#44475a",
                              palette: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                                        "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]),
              editor: .init(background: "#282a36", text: "#f8f8f2", keyword: "#ff79c6", string: "#f1fa8c", comment: "#6272a4",
                            type: "#8be9fd", number: "#bd93f9", function: "#50fa7b"))
    ]

    /// "auto" follows macOS light/dark; "ghostty" leaves the terminal to ~/.config/ghostty.
    var themes: [Theme] { Self.builtin + Theme.popular + app.extensions.all.themes }

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
        GhosttyRuntime.cleanCopy = s.bool("terminal.cleanCopy") ?? true
        if t != lastTerminal {
            lastTerminal = t
            GhosttyRuntime.appearance = t
            if GhosttyTerminalView.isLoaded { GhosttyRuntime.shared.configure(t) }
        }

        let e = theme?.editor
        let palette = e.map { CodeEditor.Palette(background: $0.background, text: $0.text, keyword: $0.keyword, string: $0.string, comment: $0.comment,
                                                 type: $0.type, number: $0.number, function: $0.function, selection: $0.selection ?? theme?.terminal?.selection,
                                                 lineHighlight: $0.lineHighlight) }
        let size = CGFloat(s.number("editor.fontSize") ?? 13), font = s.string("editor.fontFamily").flatMap { $0.isEmpty ? nil : $0 }
        let wrap = s.bool("editor.wordWrap") ?? false
        TextSize.apply(s.string("workbench.textSize"))
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
}
