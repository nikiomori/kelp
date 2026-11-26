import Foundation

extension Theme {
    /// Themes that rebuild the window, not only recolour it. Each differs from the others in what it is made of
    /// (glass, the desktop in print dots, deep water, a phosphor screen, drafting paper, printed paper), not in hue.
    /// Nothing in them moves: a backdrop drifting behind the code (Aurora, Neon, Deep Sea's motes) read as wallpaper,
    /// not a place to work.
    static let looks: [Theme] = [
        Theme(
            "kelp.glass", "Glass", "dark", c: ["#0b0e14", "#e8ecf4", "", "#2f4a6d"],
            ansi: [
                "#1a1f2b", "#ff7b72", "#7ee787", "#f2cc60", "#79c0ff", "#d2a8ff", "#76e3ea", "#d6dbe6",
                "#6e7681", "#ffa198", "#aff5b4", "#f8e3a1", "#a5d6ff", "#e2c5ff", "#b3f0ff", "#ffffff"
            ],
            code: ["#d2a8ff", "#a5d6ff", "#8b949e", "#76e3ea", "#f2cc60", "#7ee787"],
            terminalOpacity: 0.42, editorOpacity: 0.6,
            window: .init(surface: "material", border: "#ffffff1f")),
        Theme(
            "kelp.frost", "Frost", "light", c: ["#ffffff", "#1b1f27", "", "#b9d7ff"],
            ansi: [
                "#1b1f27", "#c8102e", "#086a2c", "#7f5600", "#0a5bd3", "#8a2be2", "#0b6775", "#5a616d",
                "#4b5563", "#c8102e", "#0a7334", "#8a5e00", "#0f5ed6", "#8f2fe6", "#0c7283", "#111827"
            ],
            code: ["#8a2be2", "#c8102e", "#6b7280", "#0f7b8a", "#9a6700", "#0a5bd3"],
            terminalOpacity: 0.5, editorOpacity: 0.65,
            window: .init(surface: "material", border: "#0000001f")),
        Theme(
            "kelp.halftone", "Halftone", "dark", c: ["#121119", "#eef0f6", "", "#3a4a63"],
            ansi: [
                "#2c2c30", "#ff6b6b", "#7ee787", "#e3c26a", "#6cb6ff", "#d2a8ff", "#5dd8e0", "#c7c7cc",
                "#8e8e93", "#ff8a80", "#97f3a0", "#f2d58a", "#8cc8ff", "#e0bfff", "#87e5ec", "#ffffff"
            ],
            code: ["#ff7ab2", "#ff8170", "#a3a8b8", "#5dd8ff", "#d9c97c", "#8ee6c9"],
            terminalOpacity: 0.12, editorOpacity: 0.12,
            window: .init(surface: "material", card: "#121119", ambient: "halftone")),
        Theme(
            "kelp.deep-sea", "Deep Sea", "dark", c: ["#031c20", "#cfeee8", "#4de8c2", "#0d4a52"],
            ansi: [
                "#0a2a30", "#ff7a6b", "#4de8c2", "#f2d479", "#4fb3ff", "#b79cff", "#38d9d9", "#bcdcd6",
                "#3f6b70", "#ff9d90", "#86f2d6", "#f7e3a3", "#86ccff", "#d0bfff", "#7aeaea", "#f0fffb"
            ],
            code: ["#4de8c2", "#f2d479", "#5d8a8a", "#38d9d9", "#ff9d90", "#86ccff"],
            window: .init(surface: "#021316", border: "#4de8c229", accent: "#4de8c2")),
        Theme(
            "kelp.phosphor", "Phosphor", "dark", c: ["#030703", "#33ff66", "#33ff66", "#0f4020"],
            ansi: [
                "#0a1f0e", "#ffb347", "#33ff66", "#c8ff4d", "#4dffb8", "#9dff6b", "#66ffcc", "#2fd35a",
                "#1c7a34", "#ffd08a", "#7dff9b", "#e2ff94", "#94ffd6", "#c2ffa3", "#a3ffe0", "#c8ffd6"
            ],
            code: ["#7dff9b", "#c8ff4d", "#1f8a3c", "#66ffcc", "#ffb347", "#33ff66"],
            shader: "crt",
            window: .init(
                surface: "#030703", card: "#030703", border: "#00000000", radius: 0, accent: "#33ff66", font: "mono")),
        Theme(
            "kelp.blueprint", "Blueprint", "dark", c: ["#0b2e59", "#e6f1ff", "#ffd166", "#1f5a96"],
            ansi: [
                "#0f3a6e", "#ff9e8a", "#9ee6c5", "#ffd166", "#8cc8ff", "#d2c1ff", "#7fe5f0", "#cfe3f7",
                "#6d95c0", "#ffc0b0", "#c0f2dd", "#ffe199", "#b8dcff", "#e3d8ff", "#aef0f7", "#ffffff"
            ],
            code: ["#ffd166", "#9ee6c5", "#7ba3cc", "#7fe5f0", "#ff9e8a", "#8cc8ff"],
            terminalOpacity: 0.5, editorOpacity: 0.7,
            window: .init(
                surface: "#0b2e59", border: "#ffffff66", radius: 2, accent: "#ffd166", font: "mono", ambient: "grid",
                ambientColors: ["#ffffff"])),
        Theme(
            "kelp.paper", "Paper", "light", c: ["#fbf7ee", "#2c2a26", "#b5442e", "#eadfc8"],
            ansi: [
                "#2c2a26", "#b5442e", "#4f6f3a", "#a87a1e", "#2f5f8a", "#7d4a8c", "#3b7a78", "#7a7468",
                "#6b655a", "#d0573c", "#64884a", "#c2902a", "#3f78ab", "#9660a8", "#4b9491", "#2c2a26"
            ],
            code: ["#b5442e", "#4f6f3a", "#9a9384", "#2f5f8a", "#a87a1e", "#7d4a8c"],
            window: .init(
                surface: "#efe8da", card: "#fbf7ee", border: "#2c2a2622", radius: 4, accent: "#b5442e", font: "serif")),
        Theme(
            "kelp.mono", "Mono", "light", c: ["#ffffff", "#000000", "#000000", "#ffe600"],
            ansi: [
                "#000000", "#d10000", "#000000", "#000000", "#000000", "#000000", "#000000", "#6b6b6b",
                "#6b6b6b", "#ff2a00", "#000000", "#000000", "#000000", "#000000", "#000000", "#000000"
            ],
            code: ["#000000", "#555555", "#9a9a9a", "#000000", "#000000", "#000000"],
            window: .init(
                surface: "#ffffff", card: "#ffffff", border: "#000000", borderWidth: 2, radius: 0, accent: "#ff2a00",
                font: "mono"))
    ]
}
