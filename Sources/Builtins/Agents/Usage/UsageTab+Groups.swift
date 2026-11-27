import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

// The Usage tab's two tables under the charts: where the span's tokens went by model and by project.
extension UsageReportView {
    /// A table of eight rows (`UsageGroupTable`), each with a bar for its share of the biggest, and the rest on
    /// request. A model's dot has its agent's colour. Choosing a project narrows the page to that project, and clicking
    /// it again goes back to all.
    func groups(_ title: String, _ rows: [UsageAgents.Group], all: Binding<Bool>, model: Bool) -> some View {
        let order = model ? $modelOrder : $projectOrder
        let top = rows.first.map { $0.cost > 0 ? $0.cost : Double($0.tokens) } ?? 1
        let sorted = Self.sorted(rows, by: order.wrappedValue)
        let shown = all.wrappedValue ? sorted : Array(sorted.prefix(8))
        let cells = Dictionary(shown.map { ($0.name, groupCells($0, top: top, model: model)) }) { a, _ in a }
        let figures = shown.map { "\($0.name):\($0.cost):\($0.tokens)" }.joined(separator: ",")
        return VStack(alignment: .leading, spacing: Metrics.gap) {
            Text(title).font(.ui(TextSize.body, weight: .semibold))
            UsageGroupTable(
                ids: shown.map(\.name), cells: cells, stamp: "\(range) \(sel ?? "") \(top) \(figures)",
                nameTitle: model ? String(localized: "Model") : String(localized: "Project"),
                autosave: model ? "UsageModels" : "UsageProjects", selected: model ? nil : $project, order: order)
            if rows.count > 8 {
                Button(
                    all.wrappedValue
                        ? String(localized: "Show Fewer") : String(localized: "Show All \(rows.count)")
                ) { all.wrappedValue.toggle() }
                .controlSize(.small).font(.ui(TextSize.row))   // a worded button in a page is the system's small one
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A model's or a project's cells in the columns' order: its name, its bar, its tokens and its cost.
    private func groupCells(_ group: UsageAgents.Group, top: Double, model: Bool) -> [AnyView] {
        let name = HStack(spacing: Metrics.gapWide) {
            if model {
                let owner = sel ?? series.first(where: { $0.models.contains { $0.name == group.name } })?.id
                Circle().fill(owner.map(color) ?? .clear).frame(width: 6, height: 6)
            }
            Text(model ? Self.model(group.name) : group.name).lineLimit(1).truncationMode(.middle)
        }
        let bar = MeterBar(
            share: (group.cost > 0 ? group.cost : Double(group.tokens)) / max(top, 1),
            tint: Color(nsColor: .tertiaryLabelColor), height: 3)
        return [
            cell(name), cell(bar),
            cell(Text(count(group.tokens)).foregroundStyle(.secondary).monospacedDigit(), trailing: true),
            cell(Text(money(group.cost, group.tokens)).monospacedDigit(), trailing: true)
        ]
    }

    /// The models or projects by the column the table's header names; equal ones keep the order they came in.
    nonisolated static func sorted(_ rows: [UsageAgents.Group], by order: AgentOrder) -> [UsageAgents.Group] {
        func before(_ first: UsageAgents.Group, _ second: UsageAgents.Group) -> Bool {
            switch order.by {
            case .agent: first.name.localizedStandardCompare(second.name) == .orderedAscending
            case .tokens: first.tokens < second.tokens
            case .cost: first.cost < second.cost
            }
        }
        return rows.enumerated().sorted { left, right in
            let (first, second) = order.ascending ? (left.element, right.element) : (right.element, left.element)
            if before(first, second) { return true }
            return before(second, first) ? false : left.offset < right.offset
        }.map(\.element)
    }
}
