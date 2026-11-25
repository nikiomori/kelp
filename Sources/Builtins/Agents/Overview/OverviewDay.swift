import Core
import DesignKit
import KelpKit
import SwiftUI

/// How the day's spans are painted: worked dark, waited for the user hatched, asking now orange.
enum DayPaint {
    static let worked = Color.secondary
    static let waitsNow = Color.orange
    /// Every other row's shade, as the system's tables draw it.
    static let zebra = Color(nsColor: NSColor.alternatingContentBackgroundColors.last ?? .clear)

    /// Fills `rect` with thin diagonal strokes on a faint ground, the hatching of a past wait.
    static func hatch(_ context: GraphicsContext, _ rect: CGRect) {
        guard rect.width > 0 else { return }
        context.fill(Path(rect), with: .color(Color(nsColor: .fillRest)))
        var strokes = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            strokes.move(to: CGPoint(x: x, y: rect.maxY))
            strokes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 4
        }
        var clipped = context
        clipped.clip(to: Path(rect))
        clipped.stroke(strokes, with: .color(Color(nsColor: .tertiaryLabelColor)), lineWidth: 1)
    }

    /// Paints `line`'s spans between `from` and `to` across `rect`.
    static func spans(_ line: DayLine, from: Date, to: Date, in rect: CGRect, _ context: GraphicsContext) {
        let span = max(1, to.timeIntervalSince(from))
        func x(_ date: Date) -> CGFloat {
            rect.minX + rect.width * CGFloat(max(0, min(1, date.timeIntervalSince(from) / span)))
        }
        for part in line.spans {
            let box = CGRect(
                x: x(part.from), y: rect.minY, width: max(1.5, x(part.to) - x(part.from)), height: rect.height)
            switch part.kind {
            case .worked: context.fill(Path(box), with: .color(worked))
            case .waited: hatch(context, box)
            case .waitsNow: context.fill(Path(box), with: .color(waitsNow))
            }
        }
    }
}

/// A chat's day on its card: a thin track from midnight to now.
struct DayBar: View {
    let line: DayLine
    let from: Date, to: Date
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(Color(nsColor: .fillRest)))
            DayPaint.spans(line, from: from, to: to, in: rect, context)
        }
        .accessibilityHidden(true)
    }
}

/// What the day's colours mean, beside its heading.
struct DayLegend: View {
    var body: some View {
        HStack(spacing: Metrics.inset) {
            swatch(String(localized: "worked")) { $0.fill(Path($1), with: .color(DayPaint.worked)) }
            swatch(String(localized: "waited for you")) { DayPaint.hatch($0, $1) }
            swatch(String(localized: "asks now")) { $0.fill(Path($1), with: .color(DayPaint.waitsNow)) }
        }
        .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
    }

    private func swatch(_ title: String, _ paint: @escaping (GraphicsContext, CGRect) -> Void) -> some View {
        HStack(spacing: 4) {
            Canvas { context, size in paint(context, CGRect(origin: .zero, size: size)) }.frame(width: 18, height: 8)
            Text(title)
        }
    }
}

/// The day of every chat, a lane each, under a curve of how many agents worked at once. The hours run from the first
/// work of the day to now; a click on a lane opens its chat.
struct OverviewDay: View {
    let cards: [OverviewCard]
    let hours: (from: Date, to: Date)
    let app: AppModel
    private static let label: CGFloat = 210, lane: CGFloat = 22, curve: CGFloat = 36

    var body: some View {
        let now = Date(), (from, to) = hours
        let lanes = cards.sorted { ($0.line.spans.first?.from ?? now) < ($1.line.spans.first?.from ?? now) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                Text("at once · peak \(peak(from: from, to: now))").font(.ui(TextSize.caption)).foregroundStyle(
                    .secondary
                )
                .frame(width: Self.label, alignment: .leading)
                Canvas { context, size in drawCurve(context, size, from: from, to: to, now: now) }
                    .frame(height: Self.curve)
            }
            ForEach(Array(lanes.enumerated()), id: \.element.id) { i, card in
                HStack(spacing: 0) {
                    HStack(spacing: Metrics.gap) {
                        StatusIcon(status: card.session.status, of: card.session).frame(width: 12, height: 12)
                        Text(card.session.displayTitle).font(.ui(TextSize.row)).lineLimit(1)
                            .foregroundStyle(card.session.status == .waiting ? Color.textOrange : .primary)
                    }
                    .frame(width: Self.label, alignment: .leading)
                    Canvas { context, size in
                        grid(context, size, from: from, to: to, now: now)
                        DayPaint.spans(
                            card.line, from: from, to: to, in: CGRect(x: 0, y: 5, width: size.width, height: 10),
                            context)
                    }
                }
                .frame(height: Self.lane)
                .background(i % 2 == 1 ? DayPaint.zebra : .clear)
                .contentShape(Rectangle())
                .onTapGesture { app.workbench.focus(session: card.id) }
            }
            HStack(spacing: 0) {
                Spacer().frame(width: Self.label)
                Canvas { context, size in hours(context, size, from: from, to: to) }.frame(height: 16)
            }
        }
    }

    private func peak(from: Date, to: Date) -> Int {
        DayLine.atOnce(cards.map(\.line), from: from, to: to, step: 300).max() ?? 0
    }

    private func x(_ date: Date, _ width: CGFloat, from: Date, to: Date) -> CGFloat {
        width * CGFloat(date.timeIntervalSince(from) / max(1, to.timeIntervalSince(from)))
    }

    private func grid(_ context: GraphicsContext, _ size: CGSize, from: Date, to: Date, now: Date) {
        var hour = from
        while hour <= to {
            let at = x(hour, size.width, from: from, to: to)
            context.fill(
                Path(CGRect(x: at, y: 0, width: 1, height: size.height)), with: .color(Color(nsColor: .fillRest)))
            hour = hour.addingTimeInterval(3600)
        }
        let at = x(now, size.width, from: from, to: to)
        context.fill(Path(CGRect(x: at, y: 0, width: 1, height: size.height)), with: .color(.accentColor))
    }

    private func drawCurve(_ context: GraphicsContext, _ size: CGSize, from: Date, to: Date, now: Date) {
        let step: TimeInterval = 900
        let counts = DayLine.atOnce(cards.map(\.line), from: from, to: now, step: step)
        let top = CGFloat(max(1, counts.max() ?? 1))
        var line = Path()
        for (i, n) in counts.enumerated() {
            let point = CGPoint(
                x: x(from.addingTimeInterval(Double(i) * step + step / 2), size.width, from: from, to: to),
                y: size.height - 2 - (size.height - 6) * CGFloat(n) / top)
            if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        guard !counts.isEmpty, let last = line.currentPoint else { return }
        let start = line.boundingRect.minX
        var area = line
        area.addLine(to: CGPoint(x: last.x, y: size.height))
        area.addLine(to: CGPoint(x: start, y: size.height))
        area.closeSubpath()
        context.fill(area, with: .color(Color(nsColor: .fillTint(.controlAccentColor))))
        context.stroke(line, with: .color(.accentColor), lineWidth: 1.2)
        grid(context, size, from: from, to: to, now: now)
    }

    private func hours(_ context: GraphicsContext, _ size: CGSize, from: Date, to: Date) {
        var hour = from
        let style = Date.FormatStyle(date: .omitted, time: .shortened)
        while hour <= to {
            let at = x(hour, size.width, from: from, to: to)
            context.draw(
                Text(hour.formatted(style)).font(.ui(TextSize.micro)).foregroundStyle(.secondary),
                at: CGPoint(x: min(max(at, 26), size.width - 26), y: size.height / 2))
            hour = hour.addingTimeInterval(3600)
        }
    }
}
