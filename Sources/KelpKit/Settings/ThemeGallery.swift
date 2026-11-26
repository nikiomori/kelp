import Core
import DesignKit
import SwiftUI

/// Color themes grouped by what they are: the ones that follow something, Kelp's own, the looks that rebuild the
/// window, then the classics (folded, since these palettes are well known and differ least from one another) and the
/// installed ones. Each card is a small window drawn in the theme, with its surface, its card, and its lines of text.
struct ThemeGallery: View {
    @Binding var selection: String
    /// The gallery's title and what a theme covers, shown above it as every picture row has them. Below the gallery it
    /// was half a screen from anything it could be about.
    var heading: AnyView?
    /// Shows the first row only (Match System, Ghostty, Kelp's own), as the welcome does. Settings has the rest.
    var kelpOnly = false
    @Environment(AppModel.self) private var app
    @State private var classics = false

    private var all: [Theme] { app.themes.themes }
    private var kelp: [String] { ThemeManager.builtin.map(\.id) }
    private var first: some View { grid(following(all) + all.filter { kelp.contains($0.id) }.map(card)) }

    var body: some View {
        if kelpOnly { first } else { gallery }
    }

    private var gallery: some View {
        let looks = Theme.looks.map(\.id), popular = Theme.popular.map(\.id)
        let classic = all.filter { popular.contains($0.id) }
        return VStack(alignment: .leading, spacing: Metrics.gapWide) {
            heading
            first
            Text("Looks").padding(.top, Metrics.gap)   // a group of its own, not a caption of the row above
            grid(all.filter { looks.contains($0.id) }.map(card))
            DisclosureGroup(
                isExpanded: Binding(
                    get: { classics || classic.contains { $0.id == selection } }, set: { classics = $0 })
            ) {
                grid(classic.map(card)).padding(.top, Metrics.gapWide)
            } label: {
                Text("Classics")
            }
            let installed = all.filter { !kelp.contains($0.id) && !looks.contains($0.id) && !popular.contains($0.id) }
            if !installed.isEmpty {
                Text("Installed").padding(.top, Metrics.gap)
                grid(installed.map(card))
            }
        }
        .padding(.vertical, Metrics.lineGap)
    }

    /// Lays out cards in a grid. Captions use the system font, as on every tile, because with each theme's own font
    /// (Phosphor's mono) the captions stood out of the row.
    private func grid(_ cards: [ThemeCard]) -> some View {
        TileGrid {
            ForEach(cards) { card in
                PictureTile(
                    name: card.name, on: (ThemeManager.removed[selection] ?? selection) == card.id,
                    pick: { selection = card.id }
                ) {
                    MiniWindow(card: card)
                }
            }
        }
    }

    private func card(_ theme: Theme) -> ThemeCard { ThemeCard(theme) }

    /// The Match System and Ghostty cards, drawn as the themes they stand for right now.
    private func following(_ all: [Theme]) -> [ThemeCard] {
        guard let auto = all.first(where: { $0.id == (app.themes.isDark ? "kelp.dark" : "kelp.light") }) else {
            return []
        }
        var system = ThemeCard(auto)
        system.id = "auto"
        system.name = "Match System"
        return [system, ghostty(base: ThemeCard(auto))]
    }

    /// The colours of your Ghostty config, as the terminal will show them, with the Kelp theme's colours for what the
    /// config doesn't set. A card without swatches looked like one that failed to load.
    private func ghostty(base: ThemeCard) -> ThemeCard {
        let config = GhosttyConfig.load()
        var card = base
        card.id = "ghostty"
        card.name = "Ghostty"
        card.background = config?.background.flatMap { Color(hex: $0) } ?? base.background
        card.foreground = config?.foreground.flatMap { Color(hex: $0) } ?? base.foreground
        card.lines = base.lines.enumerated().map { i, line in config?.palette[i + 1].flatMap { Color(hex: $0) } ?? line
        }
        return card
    }
}

/// The parts of a theme that a card draws.
@MainActor
private struct ThemeCard: Identifiable {
    var id: String, name: String
    var look: WindowLook
    var dark: Bool
    var background: Color, foreground: Color, accent: Color
    var lines: [Color]
    var opacity: Double

    init(_ theme: Theme) {
        id = theme.id
        name = theme.name
        look = ThemeManager.windowLook(theme, terminalOpacity: theme.terminal?.opacity ?? 1, forced: nil)
        dark = theme.appearance != "light"
        background = Color(hex: theme.terminal?.background ?? "") ?? .black
        foreground = Color(hex: theme.terminal?.foreground ?? "") ?? .white
        accent =
            (theme.window?.accent ?? theme.terminal?.palette?.dropFirst(4).first).flatMap { Color(hex: $0) }
            ?? .accentColor
        lines = (theme.terminal?.palette ?? []).dropFirst().prefix(6).compactMap { Color(hex: $0) }
        opacity = theme.terminal?.opacity ?? 1
    }
}

/// A small picture of a theme's window: the sidebar on its surface, and the card with a few lines of the terminal on
/// it.
private struct MiniWindow: View {
    let card: ThemeCard
    private var ink: Color { card.dark ? .white : .black }

    var body: some View {
        ZStack {
            surface
            ambient
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(card.accent).frame(width: 18, height: 3)
                    ForEach(0..<3, id: \.self) { index in
                        Capsule().fill(ink.opacity(0.28)).frame(width: 24 - CGFloat(index) * 5, height: 3)
                    }
                    Spacer()
                }
                .padding(.top, 7).padding(.leading, 6)
                ZStack(alignment: .topLeading) {
                    shape.fill(card.background.opacity(card.opacity))
                    shape.strokeBorder(border, lineWidth: min(card.look.borderWidth, 1))
                    text.padding(6)
                }
                .padding(.vertical, 4).padding(.trailing, 4)
            }
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: card.look.radius / 2, style: .continuous) }
    private var border: Color { card.look.border.map { Color(nsColor: $0) } ?? ink.opacity(0.12) }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(card.lines.prefix(4).enumerated()), id: \.offset) { index, color in
                HStack(spacing: 3) {
                    Capsule().fill(card.foreground.opacity(0.85)).frame(width: 14, height: 3)
                    Capsule().fill(color).frame(width: 34 - CGFloat(index * 9 % 17), height: 3)
                }
            }
        }
    }

    /// See-through themes show a desktop behind them, and macOS's material shows a window's plain grey.
    @ViewBuilder private var surface: some View {
        if let color = card.look.surface {
            Color(nsColor: color.withAlphaComponent(1))
        } else if card.look.seeThrough {
            LinearGradient(
                colors: card.dark ? [.indigo, .teal] : [.cyan.opacity(0.5), .pink.opacity(0.35)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            Color(white: card.dark ? 0.2 : 0.9)
        }
    }

    /// A drafting theme's grid.
    @ViewBuilder private var ambient: some View {
        if let effect = card.look.ambient {
            Canvas { ctx, size in
                var lines = Path()
                for x in stride(from: 0, to: size.width, by: 8) {
                    lines.addRect(CGRect(x: x, y: 0, width: 0.5, height: size.height))
                }
                for y in stride(from: 0, to: size.height, by: 8) {
                    lines.addRect(CGRect(x: 0, y: y, width: size.width, height: 0.5))
                }
                ctx.fill(lines, with: .color(Color(nsColor: effect.colors.first ?? .white).opacity(0.14)))
            }
        }
    }
}
