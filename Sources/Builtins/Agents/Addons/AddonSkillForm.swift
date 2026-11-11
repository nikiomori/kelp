import AppKit
import Core
import DesignKit
import KelpKit

/// Add a Skill (a folder or a git address to take skills from) or New Skill (a name for a SKILL.md to fill in), for
/// every agent or only in this project.
@MainActor
final class AddonSkillForm: NSObject, NSTextFieldDelegate {
    private let field = NSTextField()
    private let shared = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let alert = NSAlert()

    /// `new`: New Skill, a name; else Add a Skill, a folder or an address.
    init(new: Bool, project: String) {
        super.init()
        alert.messageText = new ? String(localized: "New Skill") : String(localized: "Add a Skill")
        alert.informativeText =
            new
            ? String(localized: "A SKILL.md to fill in, in the folder every agent reads skills from.")
            : String(
                localized: """
                    A folder with a SKILL.md, or a git address. A skill’s files can hold scripts the agent may run: \
                    only add one you trust.
                    """)
        field.placeholderString =
            new ? String(localized: "Its name, like release-notes") : String(localized: "A folder or a git address")
        field.font = .ui(TextSize.row)
        field.delegate = self
        shared.title = String(localized: "Only in \(project)")
        shared.font = .ui(TextSize.row)
        var top: [NSView] = [field]
        if !new {
            let choose = NSButton(title: String(localized: "Choose…"), target: self, action: #selector(choose))
            choose.setContentCompressionResistancePriority(.required, for: .horizontal)
            top.append(choose)
        }
        let line = NSStackView(views: top)
        line.spacing = Metrics.gap
        let column = NSStackView(views: [line, shared])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.gap
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: Metrics.alertAccessory).isActive = true
        line.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.layoutSubtreeIfNeeded()
        column.frame.size = column.fittingSize
        alert.accessoryView = column
        alert.addButton(withTitle: new ? String(localized: "Create") : String(localized: "Add"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.buttons.first?.isEnabled = false
    }

    /// What was typed and whether it's the project's only; nil when cancelled.
    func ask() async -> (text: String, project: Bool)? {
        guard await runSheet(alert) == .alertFirstButtonReturn else { return nil }
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? nil : (typed, shared.state == .on)
    }

    func controlTextDidChange(_ note: Notification) {
        alert.buttons.first?.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @objc private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Choose")
        Task {
            guard await runSheet(panel) == .OK, let url = panel.url else { return }
            field.stringValue = url.path
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        }
    }
}
