import SwiftUI
import DesignKit

/// A year of days as tiles, a column a week ending with this one (as GitHub draws contributions): the darker a tile, the
/// more the agents used that day, by quarters of the days that used anything; a day's figures on hover.
struct YearBoard: View {
    /// A day's start → what it used (cost or tokens); days missing used nothing.
    let values: [Date: Double]
    let color: Color
    /// What a tile says on hover.
    let label: (Date) -> String

    private static let tile: CGFloat = 12, gap: CGFloat = 3, weeks = 53

    var body: some View {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        let first = cal.date(byAdding: .weekOfYear, value: 1 - Self.weeks, to: cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today) ?? today
        let columns = (0..<Self.weeks).map { w in (0..<7).compactMap { cal.date(byAdding: .day, value: w * 7 + $0, to: first) } }
        let bounds = Self.quarters(values.values.filter { $0 > 0 })
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Self.gap) {
                VStack(alignment: .leading, spacing: Self.gap) {
                    Text(" ").frame(height: Self.tile)
                    ForEach(0..<7, id: \.self) { row in
                        // Every other day named, as GitHub does: Mon, Wed, Fri where weeks start on Sunday.
                        Text(row % 2 == 1 ? cal.shortWeekdaySymbols[(cal.firstWeekday - 1 + row) % 7] : " ").frame(height: Self.tile)
                    }
                }
                .padding(.trailing, 4)
                ForEach(columns.indices, id: \.self) { w in
                    VStack(spacing: Self.gap) {
                        // A month's name over the week it starts in.
                        Text(w > 0 && cal.component(.month, from: columns[w][0]) != cal.component(.month, from: columns[w - 1][0])
                             ? columns[w][0].formatted(.dateTime.month(.abbreviated)) : " ")
                            .fixedSize().frame(width: Self.tile, height: Self.tile, alignment: .leading)
                        ForEach(columns[w], id: \.self) { day in
                            if day > today { Color.clear.frame(width: Self.tile, height: Self.tile) }
                            else { tile(Self.level(values[day] ?? 0, bounds)).help(label(day)) }
                        }
                    }
                }
            }
            HStack(spacing: Self.gap) {
                Spacer()
                Text("Less").padding(.trailing, 2)
                ForEach(0..<5, id: \.self) { tile($0) }
                Text("More").padding(.leading, 2)
            }
        }
        .fixedSize(horizontal: true, vertical: false)   // the legend ends under the last week, not the panel's edge
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func tile(_ level: Int) -> some View {
        RoundedRectangle(cornerRadius: Metrics.radiusXS / 2)
            .fill(level == 0 ? Color(nsColor: .fillHover) : color.opacity([0.3, 0.5, 0.75, 1][level - 1]))
            .frame(width: Self.tile, height: Self.tile)
    }

    /// The values at a quarter, half and three quarters of the days that used anything.
    nonisolated static func quarters(_ used: [Double]) -> [Double] {
        let s = used.sorted()
        return s.isEmpty ? [] : [0.25, 0.5, 0.75].map { s[Int(Double(s.count - 1) * $0)] }
    }

    /// 0 for nothing, else 1–4: which quarter of the busy days it falls in.
    nonisolated static func level(_ v: Double, _ quarters: [Double]) -> Int {
        v <= 0 ? 0 : 1 + quarters.filter { v > $0 }.count
    }
}
