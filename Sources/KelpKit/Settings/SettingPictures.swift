import SwiftUI
import DesignKit

/// Choices about how something looks, shown as what they look like: a small drawing per option, picked like a theme,
/// instead of its name in a menu. The value written is the option, as from the menu.
enum SettingPictures {
    static let keys: Set<String> = ["workbench.textSize", "workbench.sidebar.rowHeight", "workbench.sidebar.agentDetail",
                                    "workbench.sidebar.projectColor", "agents.dockIcon", "agents.dockStrip", "terminal.cursorStyle"]
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
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: Self.columns), spacing: 10) {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { selection = o } label: {
                    VStack(alignment: .leading, spacing: 4) {   // names under the cards as the themes have theirs
                        PictureArt(key: key, option: o)
                            .frame(maxWidth: .infinity).frame(height: 64)
                            .background(Color(nsColor: .fillHover))
                            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
                                .strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: on ? 2 : 1))
                        Text(label(o)).font(.caption).fontWeight(on ? .semibold : .regular).foregroundStyle(on ? .primary : .secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(PointerCardStyle())
                .accessibilityLabel(label(o)).accessibilityAddTraits(on ? .isSelected : [])
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
        case "workbench.textSize": textSize
        case "workbench.sidebar.rowHeight": rows(["compact": 24, "regular": 28, "large": 32][option] ?? 28)
        case "workbench.sidebar.agentDetail": agentRow
        case "workbench.sidebar.projectColor": projectRow
        case "agents.dockIcon": dockIcon
        case "agents.dockStrip": dockStrip
        case "terminal.cursorStyle": cursor
        case "agents.default": agent
        default: EmptyView()
        }
    }

    private static let pink = Color(nsColor: .systemPink)

    private func row<Content: View>(height: CGFloat, fill: Color = Color.primary.opacity(0.08), @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) { content() }
            .padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading).frame(height: height)
            .background(fill, in: RoundedRectangle(cornerRadius: Metrics.radiusXS, style: .continuous))
    }

    private func line(_ width: CGFloat, _ color: Color = Color.primary.opacity(0.45)) -> some View {
        Capsule().fill(color).frame(width: width, height: 3)
    }

    /// Two rows with their text scaled as Text size scales the chrome's (1, 1.15, 1.3).
    private var textSize: some View {
        let s: CGFloat = ["large": 1.15, "larger": 1.3][option] ?? 1
        return VStack(spacing: 3) {
            row(height: 15 * s) { Text(verbatim: "Kelp").font(.caption2.weight(.semibold)).scaleEffect(s, anchor: .leading) }
            row(height: 15 * s) {
                Circle().fill(Color.textGreen).frame(width: 5, height: 5)
                Text(verbatim: "Claude").font(.caption2).scaleEffect(s, anchor: .leading)
            }
        }
        .padding(.horizontal, 12)
    }

    /// Three rows at the sidebar's own heights, halved.
    private func rows(_ points: CGFloat) -> some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                row(height: points / 2) {
                    if i > 0 { Circle().fill(Color.textGreen).frame(width: 4, height: 4) }
                    line(i == 0 ? 22 : 34)
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
                if option != "never" { line(option == "needsYou" ? 48 : 40, option == "needsYou" ? .textOrange : Color.primary.opacity(0.25)) }
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
                    RoundedRectangle(cornerRadius: Metrics.radiusXS / 2, style: .continuous).fill(Self.pink).frame(width: 10, height: 10)
                    line(40)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    /// Kelp's icon as the Dock shows it: plain, with its agents as pills at its foot, or with the plan's ring.
    private var dockIcon: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 38, height: 38)
            .overlay(alignment: .bottom) {
                if option == "agents" {
                    HStack(spacing: 2) { ForEach([Color.textGreen, .textOrange, .textGreen], id: \.self) { Capsule().fill($0).frame(width: 7, height: 4) } }
                        .offset(y: 4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if option == "usage" {
                    Circle().trim(from: 0, to: 0.62).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 13, height: 13)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 17, height: 17))
                        .offset(x: 3, y: 3)
                }
            }
    }

    /// The bottom of a screen: the Dock, and over it the strip with a question (when needed) or every agent's dot (always).
    private var dockStrip: some View {
        VStack(spacing: 4) {
            Spacer()
            if option != "off" {
                HStack(spacing: 3) {
                    if option == "needed" { Circle().fill(Color.textOrange).frame(width: 5, height: 5); line(30, .white.opacity(0.8)) }
                    else { ForEach([Color.textGreen, .textGreen, .textOrange], id: \.self) { Circle().fill($0).frame(width: 5, height: 5) } }
                }
                .padding(.horizontal, 6).frame(height: 13)
                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: Metrics.radiusXS, style: .continuous))
            }
            RoundedRectangle(cornerRadius: Metrics.radiusXS, style: .continuous).fill(Color.primary.opacity(0.18)).frame(height: 9).padding(.horizontal, 18)
        }
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.12)], startPoint: .top, endPoint: .bottom))
    }

    private var cursor: some View {
        HStack(spacing: 1) {
            Text(verbatim: "❯ ls").font(.callout.monospaced()).foregroundStyle(.white)
            Group {
                switch option {
                case "bar": Rectangle().frame(width: 2, height: 15)
                case "underline": Rectangle().frame(width: 8, height: 2).frame(height: 15, alignment: .bottom)
                default: Rectangle().frame(width: 8, height: 15)
                }
            }
            .foregroundStyle(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }

    private var agent: some View {
        Group {
            if let img = app.catalog.icon(option, size: 30) { Image(nsImage: img).resizable().frame(width: 30, height: 30) }
        }
    }
}
