// The task list's detail pane: a Linear or Jira task, or a project's item, below the list, with its state.
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

extension TasksViewController {
    // MARK: detail
    private func label(
        _ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor
    )
        -> NSTextField
    {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .ui(size, weight: weight)
        field.textColor = color
        field.isSelectable = true
        // It wraps at the pane's width: measured for a wider one, its last lines were cut in the panel.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func button(_ title: String, _ sym: String, _ action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.image = .symbol(sym)   // Kelp's own drawing where it has one (a branch, a pull request)
        button.imagePosition = .imageLeading
        button.bezelStyle = .push
        return button
    }

    func showDetail(_ row: Row?) {
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let row else {
            detail.addArrangedSubview(
                label(rows.isEmpty ? "" : String(localized: "Select an item"), color: .secondaryLabelColor))
            return
        }
        switch row {
        case .pr, .issue: return   // in a tab of its own
        case .jira(let issue):
            detail.addArrangedSubview(label("\(issue.key)  \(issue.title)", size: 17, weight: .semibold))
            detail.addArrangedSubview(jiraTransitions(issue.key, current: issue.status))
            detail.addArrangedSubview(
                button(String(localized: "Start Agent on This"), "sparkles") { [weak self] in
                    self?.startTask(ref: issue.key, title: issue.title, body: issue.description, url: issue.url)
                })
            body(issue.description)
        case .linear(let issue):
            detail.addArrangedSubview(label("\(issue.identifier)  \(issue.title)", size: 17, weight: .semibold))
            detail.addArrangedSubview(statePicker(issue))
            detail.addArrangedSubview(
                button(String(localized: "Start Agent on This"), "sparkles") { [weak self] in
                    self?.startTask(
                        ref: issue.identifier, title: issue.title, body: issue.description ?? "", url: issue.url)
                })
            body(issue.description ?? "")
        case .item(let item):
            detail.addArrangedSubview(label(item.title, size: 17, weight: .semibold))
            detail.addArrangedSubview(
                label(String(localized: "Status: \(item.status ?? "—")"), color: .secondaryLabelColor))
        }
        if let url = row.url {
            detail.addArrangedSubview(button(String(localized: "Open on the Web"), "safari") { Forge.open(url) })
        }
    }

    private func body(_ text: String) {
        detail.addArrangedSubview(
            label(
                text.isEmpty ? String(localized: "No description.") : String(text.prefix(6000)),
                color: text.isEmpty ? .secondaryLabelColor : .labelColor))
    }

    private func statePicker(_ issue: LinearIssue) -> NSView {
        let pop = NSPopUpButton()
        pop.addItem(withTitle: issue.state.name)
        Task {
            guard let states = await app.quiet(LinearStates(teamId: issue.team.id)) else { return }   // keeps the current state
            pop.removeAllItems()
            for state in states {
                pop.addItem(withTitle: state.name)
                pop.lastItem?.representedObject = state.id
            }
            pop.selectItem(withTitle: issue.state.name)
        }
        let id = issue.id
        let sink = ClosureTarget { [weak pop, app] in
            guard let sid = pop?.selectedItem?.representedObject as? String else { return }
            Task { await app.call(LinearSetState(issueId: id, stateId: sid)) }
        }
        pop.target = sink
        pop.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(pop, "sink", sink, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [NSTextField(labelWithString: String(localized: "State:")), pop])
        row.spacing = 6
        return row
    }

    private func jiraTransitions(_ key: String, current: String) -> NSView {
        let pop = NSPopUpButton()
        pop.addItem(withTitle: current.isEmpty ? String(localized: "Status") : current)
        Task {
            let ts = await app.quiet(JiraTransitions(key: key)) ?? []   // none offered: the status stays as shown
            for transition in ts {
                pop.addItem(withTitle: "→ " + transition.name)
                pop.lastItem?.representedObject = transition.id
            }
        }
        let sink = ClosureTarget { [weak pop, weak self, app] in
            guard let id = pop?.selectedItem?.representedObject as? String else { return }
            Task {
                if await app.call(JiraTransitionIssue(key: key, id: id)) != nil {
                    self?.status.stringValue = String(localized: "Moved \(key)")
                }
            }
        }
        pop.target = sink
        pop.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(pop, "sink", sink, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [NSTextField(labelWithString: String(localized: "Status:")), pop])
        row.spacing = 6
        return row
    }
}
