import Foundation

extension Theme {
    /// A popular palette: terminal + editor colors from one table. `c` = [bg, fg, cursor, selection];
    /// `ansi` = 16 colors; `code` = [keyword, string, comment, type, number, function].
    fileprivate init(_ id: String, _ name: String, _ appearance: String, c: [String], ansi: [String], code: [String]) {
        self.init(id: id, name: name, appearance: appearance,
                  terminal: .init(background: c[0], foreground: c[1], cursor: c[2], selection: c[3], palette: ansi),
                  editor: .init(background: c[0], text: c[1], keyword: code[0], string: code[1], comment: code[2],
                                type: code[3], number: code[4], function: code[5]))
    }

    static let popular: [Theme] = [
        Theme("dracula", "Dracula", "dark", c: ["#282a36", "#f8f8f2", "#f8f8f2", "#44475a"],
              ansi: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                     "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"],
              code: ["#ff79c6", "#f1fa8c", "#6272a4", "#8be9fd", "#bd93f9", "#50fa7b"]),
        Theme("tokyo-night", "Tokyo Night", "dark", c: ["#1a1b26", "#c0caf5", "#c0caf5", "#283457"],
              ansi: ["#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
                     "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5"],
              code: ["#bb9af7", "#9ece6a", "#565f89", "#2ac3de", "#ff9e64", "#7aa2f7"]),
        Theme("catppuccin-mocha", "Catppuccin Mocha", "dark", c: ["#1e1e2e", "#cdd6f4", "#f5e0dc", "#45475a"],
              ansi: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
                     "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"],
              code: ["#cba6f7", "#a6e3a1", "#6c7086", "#f9e2af", "#fab387", "#89b4fa"]),
        Theme("nord", "Nord", "dark", c: ["#2e3440", "#d8dee9", "#d8dee9", "#434c5e"],
              ansi: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                     "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"],
              code: ["#81a1c1", "#a3be8c", "#616e88", "#8fbcbb", "#b48ead", "#88c0d0"]),
        Theme("one-dark", "One Dark", "dark", c: ["#282c34", "#abb2bf", "#528bff", "#3e4451"],
              ansi: ["#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
                     "#5c6370", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#ffffff"],
              code: ["#c678dd", "#98c379", "#5c6370", "#e5c07b", "#d19a66", "#61afef"]),
        Theme("gruvbox-dark", "Gruvbox Dark", "dark", c: ["#282828", "#ebdbb2", "#ebdbb2", "#504945"],
              ansi: ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
                     "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"],
              code: ["#fb4934", "#b8bb26", "#928374", "#fabd2f", "#d3869b", "#8ec07c"]),
        Theme("solarized-dark", "Solarized Dark", "dark", c: ["#002b36", "#93a1a1", "#93a1a1", "#073642"],
              ansi: Self.solarizedAnsi, code: ["#859900", "#2aa198", "#586e75", "#b58900", "#d33682", "#268bd2"]),
        Theme("solarized-light", "Solarized Light", "light", c: ["#fdf6e3", "#586e75", "#586e75", "#eee8d5"],
              ansi: Self.solarizedAnsi, code: ["#859900", "#2aa198", "#93a1a1", "#b58900", "#d33682", "#268bd2"]),
        Theme("github-light", "GitHub Light", "light", c: ["#ffffff", "#24292f", "#0969da", "#b6d6fb"],
              ansi: ["#24292f", "#cf222e", "#116329", "#4d2d00", "#0969da", "#8250df", "#1b7c83", "#6e7781",
                     "#57606a", "#a40e26", "#1a7f37", "#633c01", "#218bff", "#a475f9", "#3192aa", "#8c959f"],
              code: ["#cf222e", "#0a3069", "#6e7781", "#953800", "#0550ae", "#8250df"])
    ]

    private static let solarizedAnsi = ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                                        "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]
}
