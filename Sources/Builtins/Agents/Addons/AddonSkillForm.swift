import AppKit
import Core
import DesignKit
import KelpKit

/// New Skill: a name for a SKILL.md to fill in, for every agent or only in this project.
@MainActor
final class AddonSkillForm: NSObject, NSTextFieldDelegate {
    private let field = NSTextField()
    private let shared = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let alert = NSAlert()

    init(project: String) {
        super.init()
        alert.messageText = String(localized: "New Skill")
        alert.informativeText = String(localized: "A SKILL.md to fill in, in the folder every agent reads skills from.")
        field.placeholderString = String(localized: "Its name, like release-notes")
        field.font = .ui(TextSize.row)
        field.delegate = self
        shared.title = String(localized: "Only in \(project)")
        shared.font = .ui(TextSize.row)
        let column = NSStackView(views: [field, shared])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.gap
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: Metrics.alertAccessory).isActive = true
        field.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.layoutSubtreeIfNeeded()
        column.frame.size = column.fittingSize
        alert.accessoryView = column
        alert.addButton(withTitle: String(localized: "Create"))
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
}
