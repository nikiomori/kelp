import AppKit
import Core
import DesignKit
import KelpKit

/// Add an MCP server: one field for what a server's page gives to paste (a command, an address or JSON), what Kelp
/// read of it underneath, and where it goes: Kelp's own file for every project, or this project's `.mcp.json`, which
/// travels with the repository.
@MainActor
final class AddonAddForm: NSObject, NSTextFieldDelegate {
    private let field = NSTextField()
    private let read = NSTextField(wrappingLabelWithString: "")
    private let shared = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let alert = NSAlert()

    /// `editing`: a server's entry as JSON, and whether it's the project's: the form changes it in place.
    init(project: String, editing: (name: String, json: String, project: Bool)? = nil) {
        super.init()
        alert.messageText =
            editing.map { String(localized: "Edit “\($0.name)”") } ?? String(localized: "Add an MCP Server")
        alert.informativeText = String(
            localized: "Claude Code and Codex get it when a chat starts. Their own settings stay as they are.")
        field.placeholderString = String(localized: "A command, an address or a JSON entry")
        field.font = .uiMono(TextSize.row)
        field.delegate = self
        read.font = .ui(TextSize.caption)
        read.textColor = .secondaryLabelColor
        shared.title = String(localized: "Only in \(project), for the team (.mcp.json)")
        shared.font = .ui(TextSize.row)
        if let editing {   // the entry as its file spells it, over several lines
            field.stringValue = editing.json
            field.usesSingleLineMode = false
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.preferredMaxLayoutWidth = Metrics.alertAccessory
            shared.state = editing.project ? .on : .off
            shared.isEnabled = false
        }
        let column = NSStackView(views: [field, read, shared])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.gap
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: Metrics.alertAccessory).isActive = true
        field.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        read.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.layoutSubtreeIfNeeded()
        column.frame.size = column.fittingSize
        alert.accessoryView = column
        alert.addButton(withTitle: editing == nil ? String(localized: "Add") : String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        show()
    }

    /// The server to add and whether it's the project's; nil when cancelled or nothing was read.
    func ask() async -> (name: String, entry: ServerEntry, project: Bool)? {
        guard await runSheet(alert) == .alertFirstButtonReturn, let found = ServerEntry.parse(field.stringValue) else {
            return nil
        }
        return (found.name, found.entry, shared.state == .on)
    }

    func controlTextDidChange(_ note: Notification) { show() }

    private func show() {
        let found = ServerEntry.parse(field.stringValue)
        read.stringValue =
            found.map(Self.words) ?? (field.stringValue.isEmpty ? " " : String(localized: "Not a server yet"))
        alert.buttons.first?.isEnabled = found != nil
    }

    /// "context7 · runs npx -y @upstash/context7-mcp · keeps CONTEXT7_API_KEY"
    static func words(_ found: (name: String, entry: ServerEntry)) -> String {
        var parts = [found.name]
        if let url = found.entry.url {
            parts.append(String(localized: "calls \(url)"))
        } else {
            let line = ([found.entry.command ?? ""] + (found.entry.args ?? [])).joined(separator: " ")
            parts.append(String(localized: "runs \(line) on this Mac"))
        }
        let secrets = (found.entry.env ?? [:]).keys.sorted() + (found.entry.headers ?? [:]).keys.sorted()
        if !secrets.isEmpty { parts.append(String(localized: "keeps \(secrets.joined(separator: ", "))")) }
        return parts.joined(separator: " · ")
    }
}
