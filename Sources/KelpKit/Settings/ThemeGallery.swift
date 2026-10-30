import SwiftUI
import Core
import DesignKit

/// Color themes by what they are: the ones that follow something, Kelp's own, the looks that rebuild the window, then the
/// classics (folded: palettes people know, which differ least from one another) and what's installed. Each card is a small
/// window in the theme: its surface, its card, its lines of text.
struct ThemeGallery: View {
    @Binding var selection: String
    @Environment(AppModel.self) private var app
    @State private var classics = false

    var body: some View {
        let all = app.themes.themes, kelp = ThemeManager.builtin.map(\.id), looks = Theme.looks.map(\.id), popular = Theme.popular.map(\.id)
        let classic = all.filter { popular.contains($0.id) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
            grid(following(all) + all.filter { kelp.contains($0.id) }.map(card))
            heading("Looks")
            grid(all.filter { looks.contains($0.id) }.map(card))
            DisclosureGroup(isExpanded: Binding(get: { classics || classic.contains { $0.id == selection } }, set: { classics = $0 })) {
                grid(classic.map(card)).padding(.top, 8)
            } label: { heading("Classics") }
            let installed = all.filter { !kelp.contains($0.id) && !looks.contains($0.id) && !popular.contains($0.id) }
            if !installed.isEmpty {
                heading("Installed")
                grid(installed.map(card))
            }
        }
        .padding(.vertical, 4)
    }

    private func heading(_ title: LocalizedStringKey) -> some View { Text(title).font(.caption).foregroundStyle(.secondary) }

    private func grid(_ cards: [ThemeCard]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
            ForEach(cards) { c in
                Button { selection = c.id } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        MiniWindow(card: c)
                            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
                                .strokeBorder(selection == c.id ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selection == c.id ? 2 : 1))
                        Text(c.name).font(.caption).fontDesign(c.design).lineLimit(1)
                    }
                }
                .buttonStyle(PointerCardStyle())
                .accessibilityLabel(c.name).accessibilityAddTraits(selection == c.id ? .isSelected : [])
            }
        }
    }

    private func card(_ t: Theme) -> ThemeCard { ThemeCard(t) }

    /// Match System and Ghostty: the themes they stand for just now.
    private func following(_ all: [Theme]) -> [ThemeCard] {
        guard let auto = all.first(where: { $0.id == (app.themes.isDark ? "kelp.dark" : "kelp.light") }) else { return [] }
        var system = ThemeCard(auto)
        system.id = "auto"; system.name = "Match System"
        return [system, ghostty(base: ThemeCard(auto))]
    }

    /// Your Ghostty config's colours, as the terminal will have them; what it doesn't set, the Kelp theme's. A card without
    /// swatches looked like one that failed to load.
    private func ghostty(base: ThemeCard) -> ThemeCard {
        let g = GhosttyConfig.load()
        var c = base
        c.id = "ghostty"; c.name = "Ghostty"
        c.background = g?.background.flatMap { Color(hex: $0) } ?? base.background
        c.foreground = g?.foreground.flatMap { Color(hex: $0) } ?? base.foreground
        c.lines = base.lines.enumerated().map { i, line in g?.palette[i + 1].flatMap { Color(hex: $0) } ?? line }
        return c
    }
}

/// What a card draws of a theme.
@MainActor
private struct ThemeCard: Identifiable {
    var id: String, name: String
    var look: WindowLook
    var dark: Bool
    var background: Color, foreground: Color, accent: Color
    var lines: [Color]
    var opacity: Double
    var design: Font.Design

    init(_ t: Theme) {
        id = t.id; name = t.name
        look = ThemeManager.windowLook(t, terminalOpacity: t.terminal?.opacity ?? 1, forced: nil)
        dark = t.appearance != "light"
        background = Color(hex: t.terminal?.background ?? "") ?? .black
        foreground = Color(hex: t.terminal?.foreground ?? "") ?? .white
        accent = (t.window?.accent ?? t.terminal?.palette?.dropFirst(4).first).flatMap { Color(hex: $0) } ?? .accentColor
        lines = (t.terminal?.palette ?? []).dropFirst().prefix(6).compactMap { Color(hex: $0) }
        opacity = t.terminal?.opacity ?? 1
        design = ["mono": .monospaced, "serif": .serif, "rounded": .rounded][t.window?.font ?? ""] ?? .default
    }
}

/// A theme's window in small: the sidebar on its surface, the card with a few lines of the terminal on it.
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
                    ForEach(0..<3, id: \.self) { i in Capsule().fill(ink.opacity(0.28)).frame(width: 24 - CGFloat(i) * 5, height: 3) }
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
        .frame(height: 72)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous))
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: card.look.radius / 2, style: .continuous) }
    private var border: Color { card.look.border.map { Color(nsColor: $0) } ?? ink.opacity(0.12) }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(card.lines.prefix(4).enumerated()), id: \.offset) { i, color in
                HStack(spacing: 3) {
                    Capsule().fill(card.foreground.opacity(0.85)).frame(width: 14, height: 3)
                    Capsule().fill(color).frame(width: 34 - CGFloat(i * 9 % 17), height: 3)
                }
            }
        }
    }

    /// See-through themes show a desktop behind them; macOS's material a window's plain grey.
    @ViewBuilder private var surface: some View {
        if let s = card.look.surface {
            Color(nsColor: s.withAlphaComponent(1))
        } else if card.look.seeThrough {
            LinearGradient(colors: card.dark ? [.indigo, .teal] : [.cyan.opacity(0.5), .pink.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            Color(white: card.dark ? 0.2 : 0.9)
        }
    }

    @ViewBuilder private var ambient: some View {
        if let a = card.look.ambient {
            let colors = a.colors.map { Color(nsColor: $0) }
            switch a.kind {
            case .aurora:
                ZStack {
                    ForEach(Array(colors.enumerated()), id: \.offset) { i, color in
                        let corner = [UnitPoint.topLeading, .topTrailing, .bottom][i % 3]
                        RadialGradient(colors: [color.opacity(0.65), .clear], center: corner, startRadius: 0, endRadius: 90)
                    }
                }
            case .motes:
                Canvas { ctx, size in
                    for i in 0..<14 {
                        let x = CGFloat((i * 37) % 100) / 100 * size.width, y = CGFloat((i * 53) % 100) / 100 * size.height, d = CGFloat(i % 3) + 1.5
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)), with: .color((colors.first ?? .white).opacity(0.6)))
                    }
                }
            case .grid:
                Canvas { ctx, size in
                    var lines = Path()
                    for x in stride(from: 0, to: size.width, by: 8) { lines.addRect(CGRect(x: x, y: 0, width: 0.5, height: size.height)) }
                    for y in stride(from: 0, to: size.height, by: 8) { lines.addRect(CGRect(x: 0, y: y, width: size.width, height: 0.5)) }
                    ctx.fill(lines, with: .color((colors.first ?? .white).opacity(0.14)))
                }
            }
        }
    }
}
