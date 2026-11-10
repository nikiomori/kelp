// A plan limit's bar and the details popover under the usage foot.
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

extension UsageView {
    /// How full a limit is (a bar can't be mistaken for the "working" spinner); orange from 70 %, red from 90 %. `pace`: a
    /// tick where an even pace would have it now, cut out of the bar on both sides so it shows on the fill as on the track.
    struct Bar: View {
        let used: Double
        var pace: Double?
        var height: CGFloat = 3
        var body: some View {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(UsageView.tint(used)).frame(width: max(height, width * min(used, 1)))
                }
                .frame(height: height)
                // An overlay, so the taller tick doesn't make the bar thicker than one without it.
                // On whole points, so it's one sharp line; flattening the bar to cut a gap round it lost the
                // popover's vibrancy (the track went black).
                .overlay(alignment: .leading) {
                    if let pace {
                        Rectangle().fill(.primary).frame(width: 1, height: height + 4).offset(
                            x: (width * pace).rounded())
                    }
                }
            }
            .frame(minWidth: 48, maxWidth: .infinity)   // a bar, not a dot, when the text beside it is long
            .frame(height: height)
        }
    }

    struct Details: View {
        let row: Row
        let forecast: LimitForecast
        let pace: Bool
        /// Each limit gets its own bar, so the one that's running out shows at a glance.
        var body: some View {
            VStack(alignment: .leading, spacing: Metrics.gapWide) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.fullName).font(.ui(TextSize.body, weight: .semibold))
                    if let at = row.readAt {
                        Text(
                            row.stale
                                ? String(localized: "Read \(shortAgo(at)) ago; not since, so these may be out of date.")
                                : Date().timeIntervalSince(at) < 60
                                    ? String(localized: "Read just now") : String(localized: "Read \(shortAgo(at)) ago")
                        )
                        .font(.ui(TextSize.caption)).foregroundStyle(row.stale ? Color.textOrange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(row.lines, id: \.label) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(line.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(UsageView.percent(line.used)).monospacedDigit().fontWeight(.semibold).foregroundStyle(
                                UsageView.tint(line.used, quiet: .primary))
                        }
                        let even = pace ? line.pace() : nil
                        Bar(used: line.used, pace: even)
                        // One line: when it resets at the left, the tick's value at the right (it wrapped as one sentence).
                        if line.resets != nil || even != nil {
                            HStack {
                                if let resets = line.resets { Text("Resets \(resets)").lineLimit(1) }
                                Spacer(minLength: Metrics.gapWide)
                                if let even {
                                    Text("Even pace \(UsageView.percent(even))").fixedSize().monospacedDigit()
                                }
                            }
                            .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                        }
                        if !row.stale,
                            let eta = forecast.warning(
                                LimitForecast.key(row.id, line.kind), resetAt: line.resetAt, window: line.window)
                        {
                            Text("At this pace it's full in \(LimitForecast.duration(eta)), before it resets.").font(
                                .ui(TextSize.caption)
                            ).foregroundStyle(Color.textOrange)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if !row.stale,
                            LimitForecast.unusedNearReset(
                                percent: line.used * 100, resetAt: line.resetAt, window: line.window)
                        {
                            Text("Over half left; what isn't used by the reset is lost.").font(.ui(TextSize.caption))
                                .foregroundStyle(
                                    .secondary
                                )
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .font(.ui(TextSize.row))
            .frame(width: 276, alignment: .leading)   // 300 with its padding, as the design's popovers are
            .padding(12)
        }
    }
}
