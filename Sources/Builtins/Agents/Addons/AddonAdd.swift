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

    init(project: String) {
        super.init()
        alert.messageText = String(localized: "Add an MCP Server")
        alert.informativeText = String(
            localized: "Claude Code and Codex get it when a chat starts. Their own settings stay as they are.")
        field.placeholderString = String(localized: "A command, an address or a JSON entry")
        field.font = .uiMono(TextSize.row)
        field.delegate = self
        read.font = .ui(TextSize.caption)
        read.textColor = .secondaryLabelColor
        shared.title = String(localized: "Only in \(project), for the team (.mcp.json)")
        shared.font = .ui(TextSize.row)
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
        alert.addButton(withTitle: String(localized: "Add"))
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

/// A row's own menu: hand a server only one agent has to the others, take away one Kelp added.
@MainActor
enum AddonMenu {
    /// The agent whose own file holds this server alone, for "Give to All Agents".
    static func only(_ addon: Addon) -> String? {
        guard addon.kind == .server, addon.source == .yours, addon.origin != Addon.kept,
            addon.agents.count == 1, let agent = addon.agents.first, ["claude", "codex"].contains(agent)
        else { return nil }
        return agent
    }

    /// One Kelp can take away: in its own file or the project's.
    static func removable(_ addon: Addon) -> Bool {
        addon.kind == .server && (addon.origin == Addon.kept || addon.origin == ".mcp.json")
    }

    static func fill(_ menu: NSMenu, _ addon: Addon, app: AppModel, worktreeId: String, done: @escaping () -> Void) {
        if let agent = only(addon), let key = addon.key {
            menu.add(String(localized: "Give to All Agents")) {
                Task {
                    let name = String(key.dropFirst("server:".count))
                    await app.call(AddonsAdd(worktreeId: worktreeId, name: name, entry: nil, from: agent))
                    done()
                }
            }
        }
        if removable(addon), let key = addon.key {
            menu.add(String(localized: "Remove…")) {
                Task {
                    let alert = NSAlert(
                        question: String(localized: "Remove “\(addon.name)”?"),
                        detail: String(localized: "New chats won’t get this server. Its entry is deleted."),
                        action: String(localized: "Remove"))
                    guard await runSheet(alert) == .alertFirstButtonReturn else { return }
                    await app.call(AddonsRemove(worktreeId: worktreeId, key: key))
                    done()
                }
            }
        }
    }
}
