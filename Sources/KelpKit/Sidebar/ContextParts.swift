import Core
import DesignKit
import SwiftUI

/// Under "Context 92% · 184k of 200k": what filled it, as a bar and a legend, biggest first — what every request starts
/// with (system prompt, tools, MCP, memory files, skills, as Claude Code's /context splits it; else one "Base"), the files
/// it read, what commands printed, the conversation, what /compact kept; then the room kept for compacting, the free
/// rest, and the tools loaded only when used. The biggest part is bold. Orange and red stay the line's: they say how full,
/// the parts' colours say what.
struct ContextParts: View {
    let parts: SessionContextParts.Parts, window: Int
    /// Compact Now: once the ring turns orange, while the agent waits for input.
    let compact: (() -> Void)?

    struct Row: Identifiable { let id: String, label: String, tokens: Int, detail: String, color: Color? }

    /// In the bar's order: the base, then the conversation's parts.
    var rows: [Row] {
        let base =
            parts.setup.map { setup in
                setup.parts.map { group in
                    Row(
                        id: "setup." + group.label, label: Self.label(group.label), tokens: group.tokens,
                        detail: Self.detail(group),
                        color: Self.color(group.label))
                }
            } ?? [
                Row(
                    id: "base", label: String(localized: "Base"), tokens: parts.base,
                    detail: String(localized: "System prompt, tools, CLAUDE.md, skills"),
                    color: Color(nsColor: .tertiaryLabelColor))
            ]
        return base
            + parts.parts.map { part in
                Row(
                    id: part.kind.rawValue, label: Self.label(part.kind), tokens: part.tokens,
                    detail: Self.detail(part),
                    color: Self.color(part.kind))
            }
    }

    var body: some View {
        let rows = self.rows, used = rows.reduce(0) { $0 + $1.tokens }, buffer = parts.setup?.buffer ?? 0
        let biggest = rows.filter { $0.id != "base" }.max { $0.tokens < $1.tokens }?.id
        let reserve = Color(nsColor: .quaternaryLabelColor)
        VStack(alignment: .leading, spacing: 6) {
            PartsBar(
                rows.map { PartsBar.Part(id: $0.id, value: Double($0.tokens), color: $0.color ?? .clear) },
                total: Double(window),
                end: buffer > 0 ? PartsBar.Part(id: "buffer", value: Double(buffer), color: reserve) : nil)
            Grid(alignment: .leading, horizontalSpacing: Metrics.gap, verticalSpacing: 3) {
                ForEach(rows.sorted { $0.tokens > $1.tokens }) { row in legend(row, bold: row.id == biggest) }
                if buffer > 0 {
                    legend(
                        Row(
                            id: "buffer", label: String(localized: "Kept for compacting"), tokens: buffer, detail: "",
                            color: reserve), bold: false)
                }
                legend(
                    Row(
                        id: "free", label: String(localized: "Free"), tokens: max(0, window - used - buffer),
                        detail: "", color: nil), bold: false)
            }
            if let deferred = parts.setup?.deferred, !deferred.isEmpty {
                Text(Self.deferred(deferred)).font(.ui(TextSize.caption)).foregroundStyle(.tertiary).fixedSize(
                    horizontal: false, vertical: true)
            }
            if let compact { Button(String(localized: "Compact Now"), action: compact).controlSize(.small) }
        }
    }

    /// Swatch, name, tokens, share of the window; what's in it on a line under the name. Each part's tokens are an
    /// estimate (the line above has the exact total).
    @ViewBuilder private func legend(_ row: Row, bold: Bool) -> some View {
        GridRow {
            PartsBar.Swatch(row.color)
            Text(row.label).fontWeight(bold ? .semibold : .regular).lineLimit(1)
            Text(shortTokens(row.tokens)).monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(Self.share(row.tokens, of: window)).monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(
                .trailing)
        }
        .font(.ui(TextSize.caption))
        if !row.detail.isEmpty {
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                Text(row.detail).font(.ui(TextSize.caption)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(
                    .tail
                )
                .gridCellColumns(3)
            }
        }
    }

    static func label(_ kind: SessionContextParts.Kind) -> String {
        switch kind {
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
    static func deferred(_ deferredItems: [SessionContextParts.Item]) -> String {
        let items = deferredItems.map { item in
            let name = label(item.label.replacingOccurrences(of: " (deferred)", with: ""))
            return "\(name) \(shortTokens(item.tokens))"
        }
        return String(localized: "Not in the context until used: \(items.joined(separator: " · "))")
    }

    static func color(_ kind: SessionContextParts.Kind) -> Color {
        switch kind {
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
    static func detail(_ part: SessionContextParts.Part) -> String {
        if part.kind == .summary { return String(localized: "What /compact kept of the conversation") }
        let items = part.top.map { item -> String in
            let name =
                switch (part.kind, item.label) {
                case (.conversation, "replies"): String(localized: "its replies")
                case (.conversation, "thinking"): String(localized: "its thinking")
                case (.conversation, "messages") where item.count == 1: String(localized: "your message")
                case (.conversation, "messages"): String(localized: "your \(item.count) messages")
                case (.conversation, "notes"): String(localized: "Claude Code's notes")
                default: item.count > 1 ? "\(item.label) ×\(item.count)" : item.label
                }
            return "\(name) \(shortTokens(item.tokens))"
        }
        let line = list(items, more: part.more, rest: part.tokens - part.top.reduce(0) { $0 + $1.tokens })
        return part.kind == .conversation ? line.prefix(1).uppercased() + line.dropFirst() : line   // "Its replies", but "npm test"
    }

    /// "CLAUDE.md 4k · MEMORY.md 3.9k", "design-review 520 · tabbit 40 · +12 more 1.2k".
    static func detail(_ group: SessionContextParts.Setup.Group) -> String {
        if group.label == "Other" {
            return String(localized: "Hook output, the environment, names of tools loaded when used")
        }
        return list(
            group.top.map { "\($0.label) \(shortTokens($0.tokens))" }, more: group.more,
            rest: max(0, group.tokens - group.top.reduce(0) { $0 + $1.tokens }))
    }

    private static func list(_ items: [String], more: Int, rest: Int) -> String {
        (items + (more > 0 ? [String(localized: "+\(more) more \(shortTokens(rest))")] : [])).joined(separator: " · ")
    }

    /// 146_200 of 1M → "14.6%".
    static func share(_ tokens: Int, of window: Int) -> String {
        (Double(tokens) / Double(max(window, 1))).formatted(.percent.precision(.fractionLength(1)))
    }
}
