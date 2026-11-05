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

    private let mode = NSSegmentedControl(labels: [String(localized: "New Branch"), String(localized: "Existing Branch"),
                                                   String(localized: "Pull Request")], trackingMode: .selectOne, target: nil, action: nil)
    let name = NSTextField(), from = NSPopUpButton(), branch = NSPopUpButton(), pr = NSPopUpButton(), agent = NSPopUpButton()
    private var rows: [Mode: [NSView]] = [:]
    private var prs: [GitHub.PullRequest] = []

    /// The sheet's fields for these branches (local, then remote) and pull requests; `base` picked in From.
    init(local: [String], remote: [String], base: String, prs: [GitHub.PullRequest], agents: [(id: String, name: String)], picked: String) {
        super.init()
        self.prs = prs
        mode.selectedSegment = 0
        mode.target = self; mode.action = #selector(modeChanged)
        mode.setEnabled(!prs.isEmpty, forSegment: Mode.pullRequest.rawValue)
        name.placeholderString = String(localized: "Named from your first prompt")
        from.addItems(withTitles: local.isEmpty ? [base] : local)
        from.selectItem(withTitle: base)
        branch.addItems(withTitles: local + remote)
        for p in prs { pr.addItem(withTitle: "#\(p.number)  \(p.title) · \(p.author)"); pr.lastItem?.representedObject = p.number }
        for a in agents { agent.addItem(withTitle: a.name); agent.lastItem?.representedObject = a.id }
        if let i = agents.firstIndex(where: { $0.id == picked }) { agent.selectItem(at: i) }
        rows = [.new: [row(String(localized: "Name"), name), row(String(localized: "From"), from)],
                .existing: [row(String(localized: "Branch"), branch)], .pullRequest: [row(String(localized: "Pull request"), pr)]]
        modeChanged()
    }

    private func row(_ label: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: Metrics.formLabel).isActive = true
        control.widthAnchor.constraint(equalToConstant: Metrics.alertAccessory - Metrics.formLabel - Metrics.gapWide).isActive = true
        let r = NSStackView(views: [l, control])
        r.spacing = Metrics.gapWide
        return r
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
        let m = Mode(rawValue: mode.selectedSegment) ?? .new
        for (k, views) in rows { for v in views { v.isHidden = k != m } }
    }

    var choice: Choice {
        let m = Mode(rawValue: mode.selectedSegment) ?? .new
        return Choice(mode: m, name: name.stringValue.trimmingCharacters(in: .whitespaces), from: from.titleOfSelectedItem,
                      branch: m == .pullRequest ? prs.first { $0.number == pr.selectedItem?.representedObject as? Int }?.headRefName
                          : branch.titleOfSelectedItem,
                      pr: m == .pullRequest ? pr.selectedItem?.representedObject as? Int : nil,
                      agent: agent.selectedItem?.representedObject as? String ?? "claude")
    }

    /// What the daemon is asked to make for `c`.
    static func request(_ c: Choice, repo: String) -> WorktreeCreate {
        switch c.mode {
        case .new: WorktreeCreate(repoId: repo, base: c.from, note: c.name.isEmpty ? nil : c.name)
        case .existing: WorktreeCreate(repoId: repo, branch: c.branch, existing: true)
        case .pullRequest: WorktreeCreate(repoId: repo, branch: c.branch, pr: c.pr)
        }
    }
}
