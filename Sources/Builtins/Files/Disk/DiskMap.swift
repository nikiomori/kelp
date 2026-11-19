import Core
import DesignKit
import SwiftUI

/// The background of a part, by its group: hatched grey for what rebuilds, a darker grey for what to check, and the
/// faintest grey for what stays. It uses greys only, because colour in Kelp means state, and none of this is state.
struct DiskFill: View {
    let group: DiskGroup
    var body: some View {
        switch group {
        case .rebuilds:
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .fillRest)))
                var lines = Path()
                for x in stride(from: -size.height, to: size.width, by: 7) {
                    lines.move(to: CGPoint(x: x, y: size.height))
                    lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                }
                context.stroke(lines, with: .color(Color(nsColor: .fillSelected)), lineWidth: 2)
            }
        case .check: Color(nsColor: .fillSelected)
        case .leftAlone: Color(nsColor: .fillRest)
        }
    }
}

/// The groups side by side, each as wide as its share of the space, so the bar pictures the project. The group
/// headings in the list serve as its legend.
struct DiskBar: View {
    let items: [RepoDiskUsage.Item]
    var body: some View {
        let total = Double(max(items.bytes, 1))
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(DiskGroup.allCases, id: \.self) { group in
                    let share = Double(items.of(group).bytes) / total
                    if share > 0 {
                        DiskFill(group: group)
                            .frame(width: max(2, (geo.size.width - 2) * share))
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }
}

/// A map of every part as a tile sized by its bytes, biggest first (`Treemap`). A click on a part that can go chooses
/// or unchooses it, as its checkbox in the list does, and a chosen tile shows an accent ring.
struct DiskMap: View {
    let items: [RepoDiskUsage.Item], root: String
    @Binding var chosen: Set<String>

    var body: some View {
        GeometryReader { geo in
            let shown = items.filter { $0.bytes > 0 }
            let rects = Treemap.layout(shown.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(shown, rects)), id: \.0.path) { item, rect in
                    tile(item, rect.insetBy(dx: Metrics.lineGap, dy: Metrics.lineGap))
                }
            }
        }
    }

    private func tile(_ item: RepoDiskUsage.Item, _ rect: CGRect) -> some View {
        let name = DiskNames.name(item, root: root), size = DiskNames.size(item.bytes), on = chosen.contains(item.path)
        let canGo = item.removable && !item.what.leftAlone
        // A button, not a tap gesture, so the keyboard and VoiceOver reach a tile as they reach its checkbox.
        return Button {
            guard canGo else { return }
            if on { chosen.remove(item.path) } else { chosen.insert(item.path) }
        } label: {
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                if rect.width > 64, rect.height > 36 {
                    Text(name).font(.ui(TextSize.row, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(size).font(.ui(TextSize.caption)).monospacedDigit()
                }
            }
            .foregroundStyle(DiskGroup(item) == .leftAlone ? .secondary : .primary)
            .padding(.horizontal, Metrics.gapWide).padding(.vertical, Metrics.gap)
            .frame(width: max(rect.width, 0), height: max(rect.height, 0), alignment: .topLeading)
            .background(DiskFill(group: DiskGroup(item)))
            .overlay(TileHover())
            .overlay(   // a page's card is a fill with no edge: only the chosen one has the accent's
                RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: on ? 2 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PointerCardStyle())
        .help("\(name) · \(size)")
        .accessibilityLabel(Text(verbatim: "\(name), \(size)"))
        .accessibilityAddTraits(on ? .isSelected : [])
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// A tile's answer to the pointer: the hover grey fades in over its fill (a page's card has no edge to brighten).
private struct TileHover: View {
    @State private var hovering = false
    var body: some View {
        Color(nsColor: .fillHover).opacity(hovering ? 1 : 0)
            .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovering)
            .onHover { hovering = $0 }
    }
}
