import Core
import DesignKit
import SwiftUI

/// Choices about how something looks, shown as what they look like: a small drawing per option, picked like a theme,
/// instead of its name in a menu (`SettingSpec.look`). The value written is the option, as from the menu.
enum SettingPictures {
    /// What the shell draws; a built-in draws its own settings' (`SettingsSection.pictures`).
    static let keys: Set<String> = [
        SettingKeys.textSize.key, SettingKeys.tabWidth.key, SettingKeys.tabHeight.key,
        SettingKeys.rowHeight.key, SettingKeys.agentDetail.key,
        SettingKeys.projectColor.key, SettingKeys.serverLook.key, SettingKeys.dockIcon.key, SettingKeys.cursorStyle.key
    ]
}

/// A setting's options as tiles: its drawing, its name under it, the chosen one ringed in the accent colour. Five to a
/// row whatever their number, so tiles are one size across the page (the agents in the welcome too).
struct PictureGrid: View {
    let key: String
    let options: [String]
    @Binding var selection: String
    let label: (String) -> String
    @Environment(AppModel.self) private var app
    /// The theme gallery's too: Kelp's five themes are one row.
    static let columns = 5

    var body: some View {
        TileGrid {
            ForEach(options, id: \.self) { choice in
                PictureTile(name: label(choice), on: choice == selection, pick: { selection = choice }) {
                    PictureArt(key: key, option: choice).frame(maxWidth: .infinity, maxHeight: .infinity).background(
                        Color(nsColor: .fillHover))
                }
            }
        }
    }
}

/// Tiles five to a row, at one spacing: the theme gallery's and every picture setting's.
struct TileGrid<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.inset), count: PictureGrid.columns),
            spacing: Metrics.inset
        ) { content }
    }
}

/// One choice: its picture at the one tile height, its name under it in the system font, picked by a click.
struct PictureTile<Art: View>: View {
    let name: String
    let on: Bool
    let pick: () -> Void
    @ViewBuilder let art: Art
    /// Themes and pictures alike, so a page of them is one grid.
    static var height: CGFloat { 64 }

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                art.frame(height: Self.height)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous))
                    .cardEdge(selected: on)
                Text(name).font(.ui(11)).fontWeight(on ? .semibold : .regular).foregroundStyle(
                    on ? .primary : .secondary
                ).lineLimit(1)
            }
        }
        .buttonStyle(PointerCardStyle())
        .accessibilityLabel(name).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A picture row's or the theme gallery's heading: its title (with ⓘ and the changed dot) over what it covers.
struct TileHeading<Title: View>: View {
    @ViewBuilder let title: Title
    let about: String?
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.lineGap) {
            title
            if let about {
                Text(about).font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One option drawn: a sidebar row, the Dock, a cursor. Schematic on purpose: lines stand for text, so the picture says the
/// same in every language.
private struct PictureArt: View {
    let key: String, option: String
    @Environment(AppModel.self) private var app

    var body: some View {
        switch key {
        case SettingKeys.textSize.key: textSize
        case SettingKeys.tabWidth.key: tabs
        case SettingKeys.tabHeight.key: tabBand(option == "compact" ? 16 : 20)
        case SettingKeys.rowHeight.key: rows(["compact": 24, "regular": 28, "large": 32][option] ?? 28)
        case SettingKeys.agentDetail.key: agentRow
        case SettingKeys.projectColor.key: projectRow
        case SettingKeys.serverLook.key: serverRow
        case SettingKeys.dockIcon.key: dockIcon
        case SettingKeys.cursorStyle.key: cursor
        case SettingKeys.defaultAgent.key: agent
        default: app.extensions.all.settings.lazy.compactMap { $0.pictures[key] }.first?(option)
        }
    }

    private static let pink = Color(nsColor: .systemPink)
    /// Text drawn into a picture at a fixed size: the Text size picture shows each size itself, so it mustn't follow the setting.
    private static func drawn(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size, weight: weight, design: design)
    }

    private func row<Content: View>(
        height: CGFloat, fill: Color = Color.primary.opacity(0.08), @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 5) { content() }
            .padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading).frame(height: height)
            .background(fill, in: RoundedRectangle(cornerRadius: Metrics.radiusXS, style: .continuous))
    }

    private func line(_ width: CGFloat, _ color: Color = Color.primary.opacity(0.45)) -> some View {
        Capsule().fill(color).frame(width: width, height: 3)
    }

    /// Two rows with their text scaled as Text size scales the chrome's (1, 1.15, 1.3).
    private var textSize: some View {
        let scale: CGFloat = ["large": 1.15, "larger": 1.3][option] ?? 1
        return VStack(spacing: 3) {
            row(height: 15 * scale) {
                Text(verbatim: "Kelp").font(Self.drawn(10, weight: .semibold)).scaleEffect(scale, anchor: .leading)
            }
            row(height: 15 * scale) {
                Circle().fill(Color.textGreen).frame(width: 5, height: 5)
                Text(verbatim: "Claude").font(Self.drawn(10)).scaleEffect(scale, anchor: .leading)
            }
        }
        .padding(.horizontal, 12)
    }

    /// A strip of tabs: two wide ones, four narrow ones, or three that narrowed as more came.
    private var tabs: some View {
        let (count, width): (Int, CGFloat) = ["regular": (2, 44), "compact": (4, 22)][option] ?? (3, 30)
        return HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 3) {
                    Circle().fill(Color.primary.opacity(0.45)).frame(width: 5, height: 5)
                    line(width - 14)
                }
                .padding(.horizontal, 4).frame(width: width, height: 14, alignment: .leading)
                .background(Color.primary.opacity(index == 0 ? 0.14 : 0.06), in: Capsule())
            }
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The strip at its height, halved, over a pane's first lines: a lower one leaves the pane more.
    private func tabBand(_ band: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule().fill(Color.primary.opacity(index == 0 ? 0.14 : 0.06)).frame(width: 30, height: band - 6)
                }
            }
            .frame(height: band)
            Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 1)
            ForEach(0..<3, id: \.self) { _ in line(50, Color.primary.opacity(0.25)) }
        }
        .padding(.horizontal, 12).padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Three rows at the sidebar's own heights, halved.
    private func rows(_ points: CGFloat) -> some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                row(height: points / 2) {
                    if index > 0 { Circle().fill(Color.textGreen).frame(width: 4, height: 4) }
                    line(index == 0 ? 22 : 34)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    /// An agent's row and, as the option says, its second line: the question (amber) or what it's doing.
    private var agentRow: some View {
        row(height: option == "never" ? 18 : 28) {
            Circle().fill(Color.textOrange).frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 4) {
                line(36)
                if option != "never" {
                    line(
                        option == "needsYou" ? 48 : 40, option == "needsYou" ? .textOrange : Color.primary.opacity(0.25)
                    )
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var projectRow: some View {
        Group {
            if option == "card" {
                row(height: 20, fill: Self.pink.opacity(0.22)) { line(40) }
                    .overlay(alignment: .leading) { Rectangle().fill(Self.pink).frame(width: 3) }
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusXS, style: .continuous))
            } else {
                row(height: 20) {
                    RoundedRectangle(cornerRadius: Metrics.radiusXS / 2, style: .continuous).fill(Self.pink).frame(
                        width: 10, height: 10)
                    line(40)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    /// A server's row as its card marks it: stripes under it all, sparser in an outline, by the icon only, or on its plate.
    private var serverRow: some View {
        let stripes = Stripes(side: option == "sparse" ? 7 : 5)
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusXS, style: .continuous)
        return row(height: 20, fill: option == "stripes" || option == "sparse" ? .clear : Color.primary.opacity(0.05)) {
            Image(systemName: "server.rack").font(Self.drawn(8, weight: .medium)).foregroundStyle(.secondary).frame(
                width: 12, height: 12
            )
            .background {
                if option == "icon" {
                    stripes.frame(width: 15, height: 15).overlay(shape.stroke(Color.primary.opacity(0.15)))
                }
            }
            line(30)
            Spacer(minLength: 0)
            line(14, Color.primary.opacity(0.25))
        }
        .background {
            switch option {
            case "stripes", "sparse": stripes.clipShape(shape)
            case "fade":
                stripes.clipShape(shape)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .black, location: 0.12), .init(color: .clear, location: 0.5)],
                            startPoint: .leading, endPoint: .trailing))
            default: EmptyView()
            }
        }
        .overlay { if option == "sparse" { shape.stroke(Color.primary.opacity(0.15)) } }
        .padding(.horizontal, 12)
    }

    /// Kelp's icon as the Dock shows it: plain, with its agents as pills at its foot, or with the plan's ring.
    private var dockIcon: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 38, height: 38)
            .overlay(alignment: .bottom) {
                if option == "agents" {
                    HStack(spacing: 2) {
                        ForEach([Color.textGreen, .textOrange, .textGreen], id: \.self) {
                            Capsule().fill($0).frame(width: 7, height: 4)
                        }
                    }
                    .offset(y: 4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if option == "usage" {
                    Circle().trim(from: 0, to: 0.62).stroke(
                        Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90)).frame(width: 13, height: 13)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 17, height: 17))
                    .offset(x: 3, y: 3)
                }
            }
    }

    /// In the terminal's own colors, as the sample above it.
    private var cursor: some View {
        let ink = app.themes.shown?.terminal.flatMap { NSColor(hex: $0.foreground) }.map(Color.init) ?? .white
        return HStack(spacing: 1) {
            Text(verbatim: "❯ ls").font(Self.drawn(12, design: .monospaced)).foregroundStyle(ink)
            Group {
                switch option {
                case "bar": Rectangle().frame(width: 2, height: 15)
                case "underline": Rectangle().frame(width: 8, height: 2).frame(height: 15, alignment: .bottom)
                default: Rectangle().frame(width: 8, height: 15)
                }
            }
            .foregroundStyle(ink.opacity(0.9))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: app.themes.terminalBackground))
    }

    private var agent: some View {
        Group {
            if let img = app.catalog.icon(option, size: 30) {
                Image(nsImage: img).resizable().frame(width: 30, height: 30)
            }
        }
    }
}

/// Settings › Appearance › Inspector › Panels: each panel's icon with a switch, in the inspector's order. The same list as
/// the icons' right-click menu; settings.json keeps the hidden ones (`workbench.inspector.hiddenPanels`).
struct InspectorPanelsRow: View {
    let title: AnyView
    let about: String?
    @Environment(AppModel.self) private var app

    var body: some View {
        let settings = app.settings
        let hidden = Set(settings[SettingKeys.hiddenPanels] ?? [])
        let order = settings[SettingKeys.panelOrder]
        let panels = app.extensions.all.panels.enumerated()
            .sorted {
                (order.firstIndex(of: $0.element.id) ?? .max, $0.offset) < (
                    order.firstIndex(of: $1.element.id) ?? .max, $1.offset
                )
            }
            .map(\.element)
        VStack(alignment: .leading, spacing: Metrics.gapWide) {
            TileHeading(title: { title }, about: about)
            ForEach(panels, id: \.id) { panel in
                Toggle(
                    isOn: Binding(
                        get: { !hidden.contains(panel.id) },
                        set: { on in
                            var next = hidden
                            if on { next.remove(panel.id) } else { next.insert(panel.id) }
                            // At least one stays: an inspector without icons has no way back but here.
                            guard next.count < panels.count else { return }
                            let kept = panels.map(\.id).filter(next.contains)
                            settings.set(SettingKeys.hiddenPanels, kept.isEmpty ? nil : kept)
                        })
                ) {
                    Label(loc(panel.title), systemImage: panel.icon)
                }
            }
        }
        .padding(.vertical, Metrics.lineGap)
    }
}

/// Thin diagonal lines `side` apart, as a server's card draws them (ProjectCard.stripes).
private struct Stripes: View {
    let side: CGFloat
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var start = -size.height
            while start < size.width {
                path.move(to: CGPoint(x: start, y: size.height))
                path.addLine(to: CGPoint(x: start + size.height, y: 0))
                start += side
            }
            context.stroke(path, with: .color(.primary.opacity(0.18)), lineWidth: 1)
        }
    }
}
