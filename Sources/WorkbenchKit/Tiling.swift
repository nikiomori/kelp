import Foundation

extension WorkspaceLayout {
    /// Each of `tabs` in a pane of its own and the other tabs together in one more, side by side: up to three in a row,
    /// more in rows of about equal panes (four make a 2×2 grid). `[]` puts every tab in one pane. Panes keep their ids
    /// where they can, so tiling what is tiled already changes nothing (dragged dividers stay). The focused tab keeps the focus.
    public mutating func tile(_ tabs: [String]) {
        let all = allTabs, was = focusedGroup?.selectedTab?.id
        guard !all.isEmpty else { return }
        let picked = all.filter { tabs.contains($0.id) }, rest = all.filter { !tabs.contains($0.id) }
        var used = Set<String>()
        func cell(_ t: [TabRef], showing shown: TabRef) -> GroupModel {
            var g = GroupModel(tabs: t, selected: shown.id)
            if let id = group(of: shown.id), used.insert(id).inserted { g.id = id }
            return g
        }
        var cells = picked.map { cell([$0], showing: $0) }
        if !rest.isEmpty {
            let shown =
                rest.first { $0.id == was } ?? rest.first { t in groups.values.contains { $0.selectedTab == t } }
                ?? rest[0]
            cells.append(cell(rest, showing: shown))
        }
        let rows = (cells.count + 2) / 3
        var next = 0
        let lines: [LayoutNode] = (0..<rows).map { r in
            let n = cells.count / rows + (r < cells.count % rows ? 1 : 0)
            defer { next += n }
            let row = cells[next..<next + n].map { LayoutNode.pane($0.id) }
            return row.count == 1 ? row[0] : .split(vertical: true, children: row)
        }
        groups = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0) })
        root = lines.count == 1 ? lines[0] : .split(vertical: false, children: lines)
        focused = was.flatMap(group(of:)) ?? cells[0].id
    }
}
