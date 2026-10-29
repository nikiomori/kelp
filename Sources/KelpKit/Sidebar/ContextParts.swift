import SwiftUI
import Core
import DesignKit

/// Under "Context 92% · 184k of 200k": what filled it, as a bar and a legend — the base the agent starts with, then the
/// files it read, what commands printed, the conversation, what /compact kept, and the free rest. The biggest part after
/// the base is bold. Orange and red stay the line's: they say how full, the parts' colours say what.
struct ContextParts: View {
    let parts: SessionContextParts.Parts, window: Int
    /// Compact Now: from 90 %, while the agent waits for input.
    let compact: (() -> Void)?

    struct Row: Identifiable { let id: String, label: String, tokens: Int, detail: String, color: Color?, estimate: Bool }

    var rows: [Row] {
        [Row(id: "base", label: String(localized: "Base"), tokens: parts.base,
             detail: String(localized: "System prompt, tools, CLAUDE.md, skills"), color: Color(nsColor: .tertiaryLabelColor), estimate: false)]
            + parts.parts.map { p in
                Row(id: p.kind.rawValue, label: Self.label(p.kind), tokens: p.tokens, detail: Self.detail(p), color: Self.color(p.kind), estimate: true)
            }
    }

    var body: some View {
        let rows = self.rows, used = rows.reduce(0) { $0 + $1.tokens }
        let biggest = rows.dropFirst().max { $0.tokens < $1.tokens }?.id
        VStack(alignment: .leading, spacing: 6) {
            PartsBar(rows.map { PartsBar.Part(id: $0.id, value: Double($0.tokens), color: $0.color ?? .clear) }, total: Double(window))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { r in legend(r, bold: r.id == biggest) }
                legend(Row(id: "free", label: String(localized: "Free"), tokens: max(0, window - used), detail: "", color: nil, estimate: false), bold: false)
            }
            if let compact { Button(String(localized: "Compact Now"), action: compact).controlSize(.small) }
        }
    }

    private func legend(_ r: Row, bold: Bool) -> some View {
        VStack(alignment: .leading, spacing: Metrics.lineGap) {
            HStack(spacing: Metrics.gap) {
                PartsBar.Swatch(r.color)
                Text(r.label).fontWeight(bold ? .semibold : .regular)
                Spacer(minLength: 8)
                Text((r.estimate ? "≈ " : "") + Self.k(r.tokens)).monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption)
            if !r.detail.isEmpty {
                Text(r.detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, PartsBar.height + Metrics.gap)
            }
        }
    }

    static func label(_ k: SessionContextParts.Kind) -> String {
        switch k {
        case .files: String(localized: "Files read")
        case .commands: String(localized: "Command output")
        case .conversation: String(localized: "Conversation")
        case .summary: String(localized: "Summary of earlier work")
        }
    }

    static func color(_ k: SessionContextParts.Kind) -> Color {
        switch k {
        case .files: .blue
        case .commands: .purple
        case .conversation: .teal
        case .summary: .cyan
        }
    }

    /// "payment.ts 17.6k · npm test ×38 66k · +7 more 22.6k"; the conversation's own words ("its replies", "your 9 messages").
    static func detail(_ p: SessionContextParts.Part) -> String {
        if p.kind == .summary { return String(localized: "What /compact kept of the conversation") }
        var items = p.top.map { i -> String in
            let name = switch (p.kind, i.label) {
            case (.conversation, "replies"): String(localized: "its replies")
            case (.conversation, "messages") where i.count == 1: String(localized: "your message")
            case (.conversation, "messages"): String(localized: "your \(i.count) messages")
            case (.conversation, "notes"): String(localized: "Claude Code's notes")
            default: i.count > 1 ? "\(i.label) ×\(i.count)" : i.label
            }
            return "\(name) \(k(i.tokens))"
        }
        if p.more > 0 { items.append(String(localized: "+\(p.more) more \(k(p.tokens - p.top.reduce(0) { $0 + $1.tokens }))")) }
        let line = items.joined(separator: " · ")
        return p.kind == .conversation ? line.prefix(1).uppercased() + line.dropFirst() : line   // "Its replies", but "npm test"
    }

    /// 17_600 → "17.6k", 31_000 → "31k", 184_000 → "184k", 640 → "640".
    static func k(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        let tenths = (n + 50) / 100
        return n >= 100_000 || tenths % 10 == 0 ? "\((n + 500) / 1000)k" : "\(tenths / 10).\(tenths % 10)k"
    }
}
