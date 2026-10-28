import AppKit
import Core
import DesignKit

/// The first launch, in one sheet: the agents found on this Mac and which one New Agent starts, a test notification
/// (so a silent banner setting shows up now, not when an agent is waiting), and Add Project.
@MainActor
final class OnboardingSheet: SheetController {
    private static var shown: OnboardingSheet?
    private let agents = NSStackView()
    private let pick = NSPopUpButton()
    private let notifyStatus = NSTextField(labelWithString: "")

    /// Once, when there's no project yet.
    static func showIfFirstLaunch(_ app: AppModel) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "onboarding.done"), app.repos.allSatisfy({ $0.path.hasPrefix(Paths.root.path) }) else { return }
        show(app)
    }

    static func show(_ app: AppModel) {
        guard shown == nil else { return }
        let s = OnboardingSheet(app: app, width: Metrics.sheetWidth)
        s.build()
        guard s.begin(ended: { shown = nil; UserDefaults.standard.set(true, forKey: "onboarding.done") }) else { return }
        shown = s
    }

    private func build() {
        let icon = NSImageView(image: NSApp.applicationIconImage); icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let title = NSTextField(labelWithString: String(localized: "Welcome to Kelp")); title.font = .ui(17, weight: .semibold)
        let sub = NSTextField(wrappingLabelWithString:
                              String(localized: "Agents work in their own workspaces here, with the terminal, editor and git next to them."))
        sub.textColor = .secondaryLabelColor; sub.preferredMaxLayoutWidth = 340
        let head = NSStackView(views: [icon, NSStackView(views: [title, sub])])
        head.alignment = .top
        head.spacing = 12
        (head.arrangedSubviews[1] as? NSStackView).map {
            $0.orientation = .vertical
            $0.alignment = .leading
            $0.spacing = 4
        }

        agents.orientation = .vertical
        agents.alignment = .leading
        agents.spacing = 6
        pick.target = self; pick.action = #selector(picked)
        let pickRow = NSStackView(views: [NSTextField(labelWithString: String(localized: "New Agent (⌥⌘T) starts:")), pick]); pickRow.spacing = 8

        let test = ClosureButton(title: String(localized: "Send Test Notification")) { [weak self] in self?.testNotification() }
        test.bezelStyle = .push
        notifyStatus.textColor = .secondaryLabelColor; notifyStatus.font = .ui(11)
        let notifyRow = NSStackView(views: [test, notifyStatus]); notifyRow.spacing = 8

        let later = ClosureButton(title: String(localized: "Later")) { [weak self] in self?.close() }
        later.bezelStyle = .push
        later.keyEquivalent = "\u{1b}"
        let add = ClosureButton(title: String(localized: "Add Project…")) { [weak self, app] in
            self?.close()
            DispatchQueue.main.async { app.workbench.addProject() }
        }
        add.bezelStyle = .push; add.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), later, add]); buttons.spacing = 8

        let stack = NSStackView(views: [head, section(String(localized: "Agents on this Mac")), agents, pickRow,
                                        section(String(localized: "Notifications")), notifyRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(18, after: head)
        stack.setCustomSpacing(18, after: pickRow)
        stack.setCustomSpacing(22, after: notifyRow)
        stack.edgeInsets = NSEdgeInsets(top: Metrics.sheetInset, left: Metrics.sheetInset, bottom: Metrics.sheetInset, right: Metrics.sheetInset)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        window?.contentView = stack
        track(owner: self) { [app] in app.availability.ids } changed: { [weak self] _ in self?.fillAgents() }
    }

    private func section(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .ui(11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func fillAgents() {
        agents.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let found = app.catalog.installed(app.catalog.all)
        let cells: [NSView] = found.map { a in
            let row = NSStackView(views: [NSImageView(image: app.catalog.icon(a.id) ?? NSImage()), NSTextField(labelWithString: a.name)]); row.spacing = 6
            return row
        }
        if !cells.isEmpty {   // two columns, like the start page
            let half = (cells.count + 1) / 2
            let grid = NSGridView(views: (0..<half).map { i in [cells[i], i + half < cells.count ? cells[i + half] : NSGridCell.emptyContentView] })
            grid.rowSpacing = 6
            grid.columnSpacing = 24
            grid.column(at: 0).width = 190
            grid.setContentHuggingPriority(.required, for: .vertical)   // else one row takes the slack
            agents.addArrangedSubview(grid)
        }
        if found.isEmpty {
            let none = NSTextField(wrappingLabelWithString: String(localized:
                "None found yet. Kelp runs agent CLIs such as Claude Code, Codex or Gemini. Pick one in the Agent Catalog and it shows up here."))
            none.textColor = .secondaryLabelColor; none.preferredMaxLayoutWidth = 410
            let open = ClosureButton(title: String(localized: "Open Agent Catalog")) { [app] in SettingsWindow.show(app, section: "catalog") }
            open.bezelStyle = .push
            agents.addArrangedSubview(none)
            agents.addArrangedSubview(open)
        }
        pick.removeAllItems()
        for a in found {
            pick.addItem(withTitle: a.name)
            pick.lastItem?.representedObject = a.id
            pick.lastItem?.image = app.catalog.icon(a.id)
        }
        pick.isEnabled = !found.isEmpty
        if let i = found.firstIndex(where: { $0.id == app.catalog.defaultAgent }) { pick.selectItem(at: i) }
    }

    @objc private func picked() {
        if let id = pick.selectedItem?.representedObject as? String { app.settings.set("agents.default", .string(id)) }
    }

    func testNotification() {
        app.notifier?.sendTest { [weak self] ok in
            self?.notifyStatus.stringValue = ok
                ? String(localized: "Sent. If no banner appeared, check Focus.") : String(localized: "Turned off for Kelp in System Settings › Notifications.")
            self?.notifyStatus.textColor = ok ? .secondaryLabelColor : .textRed
        }
    }
}
