import Foundation

extension Theme {
    /// A palette as in `popular`, with the window it comes with.
    private init(look id: String, _ name: String, _ appearance: String, c: [String], ansi: [String], code: [String],
                 terminalOpacity: Double? = nil, editorOpacity: Double? = nil, shader: String? = nil, window: Window) {
        self.init(id: id, name: name, appearance: appearance,
                  terminal: .init(background: c[0], foreground: c[1], cursor: c[2].isEmpty ? nil : c[2], selection: c[3], palette: ansi,
                                  opacity: terminalOpacity, shader: shader),
                  editor: .init(background: c[0], text: c[1], keyword: code[0], string: code[1], comment: code[2], type: code[3], number: code[4],
                                function: code[5], opacity: editorOpacity),
                  window: window)
    }

    /// Themes that rebuild the window, not only recolour it: each differs from the others in what it is made of (glass, light
    /// moving behind the text, a phosphor screen, drafting paper, printed paper), not in hue.
    static let looks: [Theme] = [
        Theme(look: "kelp.glass", "Glass", "dark", c: ["#0b0e14", "#e8ecf4", "", "#2f4a6d"],
             ansi: ["#1a1f2b", "#ff7b72", "#7ee787", "#f2cc60", "#79c0ff", "#d2a8ff", "#76e3ea", "#d6dbe6",
                    "#6e7681", "#ffa198", "#aff5b4", "#f8e3a1", "#a5d6ff", "#e2c5ff", "#b3f0ff", "#ffffff"],
             code: ["#d2a8ff", "#a5d6ff", "#8b949e", "#76e3ea", "#f2cc60", "#7ee787"],
             terminalOpacity: 0.42, editorOpacity: 0.6,
             window: .init(surface: "material", border: "#ffffff1f")),
        Theme(look: "kelp.frost", "Frost", "light", c: ["#ffffff", "#1b1f27", "", "#b9d7ff"],
             ansi: ["#1b1f27", "#c8102e", "#086a2c", "#7f5600", "#0a5bd3", "#8a2be2", "#0b6775", "#5a616d",
                    "#4b5563", "#c8102e", "#0a7334", "#8a5e00", "#0f5ed6", "#8f2fe6", "#0c7283", "#111827"],
             code: ["#8a2be2", "#c8102e", "#6b7280", "#0f7b8a", "#9a6700", "#0a5bd3"],
             terminalOpacity: 0.5, editorOpacity: 0.65,
             window: .init(surface: "material", border: "#0000001f")),
        Theme(look: "kelp.aurora", "Aurora", "dark", c: ["#080b16", "#e6e9f5", "#5ef1b5", "#2c2a5a"],
             ansi: ["#141a2e", "#ff6e96", "#5ef1b5", "#ffd479", "#7aa7ff", "#c792ff", "#5fe3e8", "#c9cfe3",
                    "#5a648a", "#ff8fb0", "#8bf7cb", "#ffe3a3", "#a0c0ff", "#dcb8ff", "#8ff0f2", "#ffffff"],
             code: ["#c792ff", "#5ef1b5", "#6f7aa3", "#5fe3e8", "#ffd479", "#7aa7ff"],
             terminalOpacity: 0.55, editorOpacity: 0.72,
             window: .init(surface: "#060814", border: "#ffffff1a", accent: "#5ef1b5", ambient: "aurora",
                           ambientColors: ["#19e3b1", "#7c5cff", "#ff4f9a"])),
        Theme(look: "kelp.deep-sea", "Deep Sea", "dark", c: ["#031c20", "#cfeee8", "#4de8c2", "#0d4a52"],
             ansi: ["#0a2a30", "#ff7a6b", "#4de8c2", "#f2d479", "#4fb3ff", "#b79cff", "#38d9d9", "#bcdcd6",
                    "#3f6b70", "#ff9d90", "#86f2d6", "#f7e3a3", "#86ccff", "#d0bfff", "#7aeaea", "#f0fffb"],
             code: ["#4de8c2", "#f2d479", "#5d8a8a", "#38d9d9", "#ff9d90", "#86ccff"],
             terminalOpacity: 0.65, editorOpacity: 0.8,
             window: .init(surface: "#021316", border: "#4de8c229", accent: "#4de8c2", ambient: "motes", ambientColors: ["#4de8c2", "#38d9d9"])),
        Theme(look: "kelp.neon", "Neon", "dark", c: ["#120524", "#f5e9ff", "#ff5cf0", "#4a1a6e"],
             ansi: ["#2a0f45", "#ff3d81", "#2dffb3", "#ffe14d", "#3da9ff", "#ff5cf0", "#2de2ff", "#e0c9f5",
                    "#7a5c99", "#ff7aa8", "#7affd1", "#fff08a", "#7ac4ff", "#ff9cf5", "#7aeeff", "#ffffff"],
             code: ["#ff5cf0", "#ffe14d", "#8a6bb0", "#2de2ff", "#ff9d4d", "#2dffb3"],
             terminalOpacity: 0.78, editorOpacity: 0.85, shader: "bloom",
             window: .init(surface: "#0e0320", border: "#ff5cf04d", radius: 14, accent: "#ff5cf0", font: "rounded", ambient: "aurora",
                           ambientColors: ["#ff2fa0", "#7b2fff", "#00d5ff"])),
        Theme(look: "kelp.phosphor", "Phosphor", "dark", c: ["#030703", "#33ff66", "#33ff66", "#0f4020"],
             ansi: ["#0a1f0e", "#ffb347", "#33ff66", "#c8ff4d", "#4dffb8", "#9dff6b", "#66ffcc", "#2fd35a",
                    "#1c7a34", "#ffd08a", "#7dff9b", "#e2ff94", "#94ffd6", "#c2ffa3", "#a3ffe0", "#c8ffd6"],
             code: ["#7dff9b", "#c8ff4d", "#1f8a3c", "#66ffcc", "#ffb347", "#33ff66"],
             shader: "crt",
             window: .init(surface: "#030703", card: "#030703", border: "#00000000", radius: 0, accent: "#33ff66", font: "mono")),
        Theme(look: "kelp.blueprint", "Blueprint", "dark", c: ["#0b2e59", "#e6f1ff", "#ffd166", "#1f5a96"],
             ansi: ["#0f3a6e", "#ff9e8a", "#9ee6c5", "#ffd166", "#8cc8ff", "#d2c1ff", "#7fe5f0", "#cfe3f7",
                    "#6d95c0", "#ffc0b0", "#c0f2dd", "#ffe199", "#b8dcff", "#e3d8ff", "#aef0f7", "#ffffff"],
             code: ["#ffd166", "#9ee6c5", "#7ba3cc", "#7fe5f0", "#ff9e8a", "#8cc8ff"],
             terminalOpacity: 0.5, editorOpacity: 0.7,
             window: .init(surface: "#0b2e59", border: "#ffffff66", radius: 2, accent: "#ffd166", font: "mono", ambient: "grid",
                           ambientColors: ["#ffffff"])),
        Theme(look: "kelp.paper", "Paper", "light", c: ["#fbf7ee", "#2c2a26", "#b5442e", "#eadfc8"],
             ansi: ["#2c2a26", "#b5442e", "#4f6f3a", "#a87a1e", "#2f5f8a", "#7d4a8c", "#3b7a78", "#7a7468",
                    "#6b655a", "#d0573c", "#64884a", "#c2902a", "#3f78ab", "#9660a8", "#4b9491", "#2c2a26"],
             code: ["#b5442e", "#4f6f3a", "#9a9384", "#2f5f8a", "#a87a1e", "#7d4a8c"],
             window: .init(surface: "#efe8da", card: "#fbf7ee", border: "#2c2a2622", radius: 4, accent: "#b5442e", font: "serif")),
        Theme(look: "kelp.mono", "Mono", "light", c: ["#ffffff", "#000000", "#000000", "#ffe600"],
             ansi: ["#000000", "#d10000", "#000000", "#000000", "#000000", "#000000", "#000000", "#6b6b6b",
                    "#6b6b6b", "#ff2a00", "#000000", "#000000", "#000000", "#000000", "#000000", "#000000"],
             code: ["#000000", "#555555", "#9a9a9a", "#000000", "#000000", "#000000"],
             window: .init(surface: "#ffffff", card: "#ffffff", border: "#000000", borderWidth: 2, radius: 0, accent: "#ff2a00", font: "mono"))
    ]
}
