import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

// The Usage tab's two lists under the charts: where the span's tokens went by model and by project.
extension UsageReportView {
    /// A list of eight rows, each with a bar for its share of the first row, and the rest on request. A model's dot has
    /// its agent's colour. Clicking a project narrows the page to that project, and clicking it again goes back to all.
    func groups(_ title: String, _ rows: [UsageAgents.Group], all: Binding<Bool>, model: Bool) -> some View {
        let top = rows.first.map { $0.cost > 0 ? $0.cost : Double($0.tokens) } ?? 1
        return VStack(alignment: .leading, spacing: Metrics.gap) {
            Text(title).font(.ui(TextSize.body, weight: .semibold))
            ForEach(all.wrappedValue ? rows : Array(rows.prefix(8)), id: \.name) { group in
                let content = HStack(spacing: Metrics.gapWide) {
                    if model {
                        let owner = sel ?? series.first(where: { $0.models.contains { $0.name == group.name } })?.id
                        Circle().fill(owner.map(color) ?? .clear).frame(width: 6, height: 6)
                    }
                    Text(model ? Self.model(group.name) : group.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Metrics.inset)
                    MeterBar(
                        share: (group.cost > 0 ? group.cost : Double(group.tokens)) / max(top, 1),
                        tint: Color(nsColor: .tertiaryLabelColor), height: 3
                    )
                    .frame(width: 120)
                    Text(count(group.tokens)).foregroundStyle(.secondary).monospacedDigit().frame(
                        width: 56, alignment: .trailing)
                    Text(money(group.cost, group.tokens)).monospacedDigit().frame(width: 72, alignment: .trailing)
                }
                .font(.ui(TextSize.row)).frame(minHeight: TextSize.of(Metrics.row)).contentShape(Rectangle())
                if model {
                    content
                } else {
                    // A project is a button that answers the pointer and a press as every row does; the one the page
                    // is narrowed to keeps the selection's fill. `flush` keeps its words in line with the models'.
                    Button {
                        project = project == group.name ? nil : group.name
                    } label: {
                        content
                    }
                    .buttonStyle(PointerButtonStyle(flush: true))
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                            .fill(Color(nsColor: project == group.name ? .fillSelected : .clear))
                            .padding(.horizontal, -Metrics.lineGap * 2)   // as far past the words as the style's fill
                    )
                }
                Divider()
            }
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
}
