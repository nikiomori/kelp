import SwiftUI
import Core
import DesignKit

/// Under "Context 92% · 184k of 200k": what filled it, as a bar and a legend, biggest first — what every request starts
/// with (system prompt, tools, MCP, memory files, skills, as Claude Code's /context splits it; else one "Base"), the files
/// it read, what commands printed, the conversation, what /compact kept; then the room kept for compacting, the free
/// rest, and the tools loaded only when used. The biggest part is bold. Orange and red stay the line's: they say how full,
/// the parts' colours say what.
struct ContextParts: View {
    let parts: SessionContextParts.Parts, window: Int
    /// Compact Now: from 90 %, while the agent waits for input.
    let compact: (() -> Void)?

    struct Row: Identifiable { let id: String, label: String, tokens: Int, detail: String, color: Color? }

    /// In the bar's order: the base, then the conversation's parts.
    var rows: [Row] {
        let base = parts.setup.map { s in
            s.parts.map { g in Row(id: "setup." + g.label, label: Self.label(g.label), tokens: g.tokens, detail: Self.detail(g), color: Self.color(g.label)) }
        } ?? [Row(id: "base", label: String(localized: "Base"), tokens: parts.base,
                  detail: String(localized: "System prompt, tools, CLAUDE.md, skills"), color: Color(nsColor: .tertiaryLabelColor))]
        return base + parts.parts.map { p in
            Row(id: p.kind.rawValue, label: Self.label(p.kind), tokens: p.tokens, detail: Self.detail(p), color: Self.color(p.kind))
        }
    }

    var body: some View {
        let rows = self.rows, used = rows.reduce(0) { $0 + $1.tokens }, buffer = parts.setup?.buffer ?? 0
        let biggest = rows.filter { $0.id != "base" }.max { $0.tokens < $1.tokens }?.id
        let reserve = Color(nsColor: .quaternaryLabelColor)
        VStack(alignment: .leading, spacing: 6) {
            PartsBar(rows.map { PartsBar.Part(id: $0.id, value: Double($0.tokens), color: $0.color ?? .clear) }, total: Double(window),
                     end: buffer > 0 ? PartsBar.Part(id: "buffer", value: Double(buffer), color: reserve) : nil)
            Grid(alignment: .leading, horizontalSpacing: Metrics.gap, verticalSpacing: 3) {
                ForEach(rows.sorted { $0.tokens > $1.tokens }) { r in legend(r, bold: r.id == biggest) }
                if buffer > 0 {
                    legend(Row(id: "buffer", label: String(localized: "Kept for compacting"), tokens: buffer, detail: "", color: reserve), bold: false)
                }
                legend(Row(id: "free", label: String(localized: "Free"), tokens: max(0, window - used - buffer), detail: "", color: nil), bold: false)
            }
            if let d = parts.setup?.deferred, !d.isEmpty {
                Text(Self.deferred(d)).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if let compact { Button(String(localized: "Compact Now"), action: compact).controlSize(.small) }
        }
    }

    /// Swatch, name, tokens, share of the window; what's in it on a line under the name. Each part's tokens are an
    /// estimate (the line above has the exact total).
    @ViewBuilder private func legend(_ r: Row, bold: Bool) -> some View {
        GridRow {
            PartsBar.Swatch(r.color)
            Text(r.label).fontWeight(bold ? .semibold : .regular).lineLimit(1)
            Text(Self.k(r.tokens)).monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(Self.share(r.tokens, of: window)).monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
        }
        .font(.caption)
        if !r.detail.isEmpty {
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                Text(r.detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail).gridCellColumns(3)
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

    /// Claude Code's names for what a request starts with, in the app's language.
    static func label(_ claude: String) -> String {
        switch claude {
        case "System prompt": String(localized: "System prompt")
        case "System tools": String(localized: "Built-in tools")
        case "MCP tools": String(localized: "MCP tools")
        case "MCP server instructions": String(localized: "MCP server instructions")
        case "Custom agents": String(localized: "Subagents")
        case "Memory files": String(localized: "Memory files")
        case "Skills": String(localized: "Skills")
        case "Other": String(localized: "Other at start")
        default: claude
        }
    }

    /// "Not in the context until used: MCP tools 46.8k · built-in tools 13.7k" (Claude Code's "MCP tools (deferred)"…).
    static func deferred(_ d: [SessionContextParts.Item]) -> String {
        let items = d.map { i in
            let name = label(i.label.replacingOccurrences(of: " (deferred)", with: ""))
            return "\(name) \(k(i.tokens))"
        }
        return String(localized: "Not in the context until used: \(items.joined(separator: " · "))")
    }

    static func color(_ k: SessionContextParts.Kind) -> Color {
        switch k {
        case .files: .blue
        case .commands: .purple
        case .conversation: .teal
        case .summary: .cyan
        }
    }

    static func color(_ claude: String) -> Color {
        switch claude {
        case "System prompt": .gray
        case "System tools": .orange
        case "MCP tools": .green
        case "MCP server instructions": .mint
        case "Custom agents": .indigo
        case "Memory files": .yellow
        case "Skills": .pink
        case "Other": Color(nsColor: .tertiaryLabelColor)
        default: .brown
        }
    }

    /// "payment.ts 17.6k · npm test ×38 66k · +7 more 22.6k"; the conversation's own words ("its replies", "your 9 messages").
    static func detail(_ p: SessionContextParts.Part) -> String {
        if p.kind == .summary { return String(localized: "What /compact kept of the conversation") }
        let items = p.top.map { i -> String in
            let name = switch (p.kind, i.label) {
            case (.conversation, "replies"): String(localized: "its replies")
            case (.conversation, "messages") where i.count == 1: String(localized: "your message")
            case (.conversation, "messages"): String(localized: "your \(i.count) messages")
            case (.conversation, "notes"): String(localized: "Claude Code's notes")
            default: i.count > 1 ? "\(i.label) ×\(i.count)" : i.label
            }
            return "\(name) \(k(i.tokens))"
        }
        let line = list(items, more: p.more, rest: p.tokens - p.top.reduce(0) { $0 + $1.tokens })
        return p.kind == .conversation ? line.prefix(1).uppercased() + line.dropFirst() : line   // "Its replies", but "npm test"
    }

    /// "CLAUDE.md 4k · MEMORY.md 3.9k", "design-review 520 · tabbit 40 · +12 more 1.2k".
    static func detail(_ g: SessionContextParts.Setup.Group) -> String {
        if g.label == "Other" { return String(localized: "Hook output, the environment, names of tools loaded when used") }
        return list(g.top.map { "\($0.label) \(k($0.tokens))" }, more: g.more, rest: max(0, g.tokens - g.top.reduce(0) { $0 + $1.tokens }))
    }

    private static func list(_ items: [String], more: Int, rest: Int) -> String {
        (items + (more > 0 ? [String(localized: "+\(more) more \(k(rest))")] : [])).joined(separator: " · ")
    }

    /// 17_600 → "17.6k", 31_000 → "31k", 184_000 → "184k", 640 → "640".
    static func k(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        let tenths = (n + 50) / 100
        return n >= 100_000 || tenths % 10 == 0 ? "\((n + 500) / 1000)k" : "\(tenths / 10).\(tenths % 10)k"
    }

    /// 146_200 of 1M → "14.6%".
    static func share(_ n: Int, of window: Int) -> String {
        (Double(n) / Double(max(window, 1))).formatted(.percent.precision(.fractionLength(1)))
    }
}
