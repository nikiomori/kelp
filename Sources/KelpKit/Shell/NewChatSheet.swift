import AppKit
import Core
import DesignKit

/// ⌥⌃⌘N, "New Chat on Branch…": a new branch with a name of your choosing, a branch that's there already, or a pull
/// request, each in a folder of its own, and the agent to start there. ⌃⌘N stays one keystroke, named by the first prompt.
@MainActor
final class NewChatSheet: NSObject {
    enum Mode: Int { case new, existing, pullRequest }
    struct Choice: Equatable {
        var mode: Mode, name: String, from: String?, branch: String?, pr: Int?, agent: String
    }

    private let mode = NSSegmentedControl(
        labels: [
            String(localized: "New Branch"), String(localized: "Existing Branch"),
            String(localized: "Pull Request")
        ], trackingMode: .selectOne, target: nil, action: nil)
    let name = NSTextField(), from = NSPopUpButton(), branch = NSPopUpButton(), pr = NSPopUpButton(),
        agent = NSPopUpButton()
    private var rows: [Mode: [NSView]] = [:]
    private var prs: [GitHub.PullRequest] = []

    /// The sheet's fields for these branches (local, then remote) and pull requests; `base` picked in From.
    init(
        local: [String], remote: [String], base: String, prs: [GitHub.PullRequest],
        agents: [(id: String, name: String)], picked: String
    ) {
        super.init()
        self.prs = prs
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setEnabled(!prs.isEmpty, forSegment: Mode.pullRequest.rawValue)
        name.placeholderString = String(localized: "Named from your first prompt")
        from.addItems(withTitles: local.isEmpty ? [base] : local)
        from.selectItem(withTitle: base)
        branch.addItems(withTitles: local + remote)
        for request in prs {
            pr.addItem(withTitle: "#\(request.number)  \(request.title) · \(request.author)")
            pr.lastItem?.representedObject = request.number
        }
        for option in agents {
            agent.addItem(withTitle: option.name)
            agent.lastItem?.representedObject = option.id
        }
        if let index = agents.firstIndex(where: { $0.id == picked }) { agent.selectItem(at: index) }
        rows = [
            .new: [row(String(localized: "Name"), name), row(String(localized: "From"), from)],
            .existing: [row(String(localized: "Branch"), branch)],
            .pullRequest: [row(String(localized: "Pull request"), pr)]
        ]
        modeChanged()
    }

    private func row(_ label: String, _ control: NSView) -> NSView {
        let caption = NSTextField(labelWithString: label)
        caption.alignment = .right
        caption.widthAnchor.constraint(equalToConstant: Metrics.formLabel).isActive = true
        control.widthAnchor.constraint(equalToConstant: Metrics.alertAccessory - Metrics.formLabel - Metrics.gapWide)
            .isActive = true
        let line = NSStackView(views: [caption, control])
        line.spacing = Metrics.gapWide
        return line
    }

    /// The fields: the mode on top, its own rows, the agent last.
    var view: NSView {
        let all = [Mode.new, .existing, .pullRequest].flatMap { rows[$0] ?? [] }
        let stack = NSStackView(views: [mode] + all + [row(String(localized: "Agent"), agent)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.gapWide
        stack.frame = NSRect(x: 0, y: 0, width: Metrics.alertAccessory, height: stack.fittingSize.height)
        return stack
    }

    @objc private func modeChanged() {
        let current = Mode(rawValue: mode.selectedSegment) ?? .new
        for (kind, views) in rows { for view in views { view.isHidden = kind != current } }
    }

    var choice: Choice {
        let current = Mode(rawValue: mode.selectedSegment) ?? .new
        return Choice(
            mode: current, name: name.stringValue.trimmingCharacters(in: .whitespaces), from: from.titleOfSelectedItem,
            branch: current == .pullRequest
                ? prs.first { $0.number == pr.selectedItem?.representedObject as? Int }?.headRefName
                : branch.titleOfSelectedItem,
            pr: current == .pullRequest ? pr.selectedItem?.representedObject as? Int : nil,
            agent: agent.selectedItem?.representedObject as? String ?? "claude")
    }

    /// What the daemon is asked to make for `choice`.
    static func request(_ choice: Choice, repo: String) -> WorktreeCreate {
        switch choice.mode {
        case .new: WorktreeCreate(repoId: repo, base: choice.from, note: choice.name.isEmpty ? nil : choice.name)
        case .existing: WorktreeCreate(repoId: repo, branch: choice.branch, existing: true)
        case .pullRequest: WorktreeCreate(repoId: repo, branch: choice.branch, pr: choice.pr)
        }
    }
}
