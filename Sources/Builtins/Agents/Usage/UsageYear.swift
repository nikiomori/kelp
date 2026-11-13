import Charts
import DesignKit
import SwiftUI

/// The last 12 months, a bar each with its figure over it; this month, not over yet, lighter.
struct MonthBars: View {
    let months: [(start: Date, value: Double)]
    let color: Color
    let label: (Double) -> String

    var body: some View {
        let now = Calendar.current.dateInterval(of: .month, for: Date())?.start
        Chart(months, id: \.start) { month in
            BarMark(x: .value("Month", month.start, unit: .month), y: .value("Used", month.value))
                .foregroundStyle(color.opacity(month.start == now ? 0.5 : 1))
                .annotation(position: .top) {
                    if month.value > 0 {
                        Text(label(month.value)).font(.ui(TextSize.micro)).foregroundStyle(.secondary)
                    }
                }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks { axisValue in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = axisValue.as(Double.self) { Text(label(amount)) }
                }
            }
        }
        .frame(height: 110)
    }

    /// Days' figures (by the day's start) summed into the 12 months up to `now`'s, the oldest first.
    nonisolated static func months(_ days: [Date: Double], now: Date = Date(), calendar: Calendar = .current) -> [(
        start: Date, value: Double
    )] {
        guard let this = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        let starts = (0..<12).reversed().compactMap { calendar.date(byAdding: .month, value: -$0, to: this) }
        var sums = Dictionary(uniqueKeysWithValues: starts.map { ($0, 0.0) })
        for (day, value) in days {
            if let start = calendar.dateInterval(of: .month, for: day)?.start, sums[start] != nil {
                sums[start, default: 0] += value
            }
        }
        return starts.map { ($0, sums[$0] ?? 0) }
    }
}
