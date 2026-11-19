import AppKit
import Core
import DesignKit
import KelpKit

/// Draws the list's rows: a PR or an issue from `ForgeRows`, and a tracker's task as a title over a line.
extension TasksViewController {
    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }
    func tableView(_ tableView: NSTableView, heightOfRow index: Int) -> CGFloat {
        guard let row = row(at: index) else { return TextSize.of(Metrics.rowSection) }
        let width = max(80, table.bounds.width - ForgeRows.titleMargin)
        switch row {
        case .pr(let pr): return ForgeRows.height(title: pr.title, width: width)
        case .issue(let issue): return ForgeRows.height(title: issue.title, width: width)
        case .linear, .jira, .item: return TextSize.of(Metrics.rowTwoLine)
        }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow index: Int) -> Bool { row(at: index) != nil }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row index: Int) -> NSView? {
        guard let row = row(at: index) else {
            if case .heading(let text) = lines[index] { return ForgeRows.heading(text) }
            return nil
        }
        switch row {
        case .pr(let pr):
            let folder = repoId.map { PRWork(app: app, repoId: $0, pr: pr).worktree != nil } ?? false
            return ForgeRows.pr(pr, worktree: folder, unseen: unseen.contains(pr.number))
        case .issue(let issue):
            let working = app.worktrees.contains {
                $0.repoId == repoId && $0.issue == "#\(issue.number)" && !$0.archived
            }
            return ForgeRows.issue(issue, working: working)
        case .linear, .jira, .item: return trackerCell(row)
        }
    }

    /// The row for a tracker's task or a project's item: its title, with a line under it.
    func trackerCell(_ row: Row) -> NSView {
        let (title, sub): (String, String) =
            switch row {
            case .linear(let issue): ("\(issue.identifier)  \(issue.title)", "\(issue.state.name) · \(issue.team.name)")
            case .jira(let issue):
                ("\(issue.key)  \(issue.title)", "\(issue.status) · \(issue.type) · \(issue.project)")
            case .item(let item): (item.title, "\(item.status ?? String(localized: "No status")) · \(item.type)")
            case .pr(let pr): ("#\(pr.number)  \(pr.title)", pr.author)
            case .issue(let issue): ("#\(issue.number)  \(issue.title)", "")
            }
        let t1 = NSTextField(labelWithString: title)
        t1.font = .ui(TextSize.row)   // a list's row, as a pull request's in Issues & PRs
        t1.lineBreakMode = .byTruncatingTail
        let t2 = NSTextField(labelWithString: sub)
        t2.font = .ui(TextSize.caption)
        t2.textColor = .secondaryLabelColor
        t2.lineBreakMode = .byTruncatingTail
        // The fields give way to the stack's insets, so a title that doesn't fit is cut there, not pushed out past the
        // line under it.
        for field in [t1, t2] { field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let stack = NSStackView(views: [t1, t2])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.lineGap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        return stack
    }
    /// A heading does nothing on a click, so it doesn't light up under the pointer as the rows under it do.
    func tableView(_ tableView: NSTableView, rowViewForRow index: Int) -> NSTableRowView? {
        let heading = row(at: index) == nil
        return ListRowView(lights: { _ in !heading })
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let picked = row(at: table.selectedRow)
        switch picked {
        case .pr(let pr)?:
            open(.pr, pr.number)
            PRWatch.saw(pr)
            if unseen.remove(pr.number) != nil {
                table.reloadData(forRowIndexes: [table.selectedRow], columnIndexes: [0])
            }
        case .issue(let issue)?: open(.issue, issue.number)
        case .linear?, .jira?, .item?, nil: break
        }
        let tracker =
            picked.map { if case .pr = $0 { false } else if case .issue = $0 { false } else { true } } ?? false
        showDetailPane(tracker)
        showDetail(tracker ? picked : nil)
    }
}
