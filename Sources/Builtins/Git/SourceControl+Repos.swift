// Source Control for a folder that holds several repositories side by side (`RepoKey`): a section for each, one message
// that commits in each repository with something to commit, and the repositories' branches in the header. The daemon
// takes the folder's id and each file's path ("frontend/src/a.ts") and acts in the file's repository, so staging,
// discarding, diffs and commits go through the same calls as in a folder that is one repository.
import AppKit
import Core
import DesignKit
import KelpKit

extension SourceControlController {
    /// The repository a change is in: its path's first part.
    static func repo(of path: String) -> String { String(path.prefix { $0 != "/" }) }

    /// Where a commit goes: the repositories with staged files, or, with nothing staged anywhere, those with changes.
    var committing: [String] {
        let staged = changes.filter { $0.staged && !$0.conflicted }
        return Array(Set((staged.isEmpty ? changes : staged).map { Self.repo(of: $0.path) })).sorted()
    }

    /// The header's words: the branch every repository is on and how many there are, or how many branches.
    var branchesTitle: String {
        var event = GitEvent(worktree: "")
        (event.repos, event.repoBranches) = (repos, repoBranches)
        return event.branchTitle ?? ""
    }

    /// The commit button's words in a folder of repositories.
    var severalCommitTitle: String {
        let into = committing
        guard into.count > 1 else {
            return into.first.map { String(localized: "Commit in \($0)") } ?? String(localized: "Commit")
        }
        return String(localized: "Commit in \(into.count) Repositories")
    }

    /// With nothing to commit, Sync Changes when a repository has commits to pull or push.
    var severalNext: String? {
        let moves = repoBranches.values.contains { ($0.ahead ?? 0) + ($0.behind ?? 0) > 0 }
        return moves ? String(localized: "Sync Changes") : nil
    }

    /// A section for each repository, its changes under it, each file once. A repository with no changes shows folded
    /// with none, so every repository of the folder is listed.
    func repoSections(_ names: [String], _ rows: inout Rows) -> [Node] {
        names.map { name in
            let files = changes.filter { Self.repo(of: $0.path) == name }
            let node = rows.node("r \(name)", .repo(name))
            node.files = files
            node.children =
                collapsed.contains("repo " + name)
                ? []
                : files.map { file in
                    let section: Section =
                        file.conflicted ? .merge : file.staged && !file.unstaged ? .staged : .changes
                    let plan = section == .merge ? nil : worktreeId.flatMap { plans[$0]?.number(of: file.path) }
                    return rows.node(
                        "\(section.rawValue) \(file.path)", .file(file, section),
                        look: .file(file, shared: shared[file.path] ?? [], commit: plan))
                }
            return node
        }
    }

    /// A repository's row: its name and count, and its branch where a section shows its lines.
    func repoCell(_ outline: NSOutlineView, _ node: Node, _ name: String) -> NSView {
        let cell = outline.makeView(withIdentifier: SectionCell.id, owner: nil) as? SectionCell ?? SectionCell()
        cell.show(
            title: name, count: node.files.count,
            expanded: !collapsed.contains("repo " + name) && !node.files.isEmpty,
            actions: node.files.isEmpty ? [] : sectionActions(.changes, node), detail: branchText(name))
        cell.toolTip = repoBranches[name]?.current.map { String(localized: "\(name) is on \($0)") }
        return cell
    }

    private func branchText(_ name: String) -> NSAttributedString? {
        guard let branch = repoBranches[name]?.current else { return nil }
        let font = NSFont.ui(TextSize.caption), text = NSMutableAttributedString()
        // The branch glyph the header's chip draws (Kelp's own), in the text's shade: an attachment draws a template
        // in black.
        do {
            let glyph = NSImage.symbol("arrow.triangle.branch", size: Metrics.iconTiny)
            let image = NSImage(size: glyph.size, flipped: false) { rect in
                glyph.draw(in: rect)
                NSColor.secondaryLabelColor.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let sign = NSTextAttachment()
            sign.image = image
            sign.bounds = NSRect(origin: NSPoint(x: 0, y: (font.capHeight - image.size.height) / 2), size: image.size)
            text.append(NSAttributedString(attachment: sign))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: branch))
        text.addAttributes(
            [.font: font, .foregroundColor: NSColor.secondaryLabelColor],
            range: NSRange(location: 0, length: text.length))
        return text
    }

    func toggleRepo(_ name: String) {
        let key = "repo " + name
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        if view.window != nil { outline.crossfade(Motion.base) }
        rebuildChanges()
    }

    /// The branch chip's menu in a folder of repositories: each one and its branch. A branch is switched in its own
    /// repository (its terminal), because one switch for several isn't one move.
    func repoBranchMenu() {
        let menu = NSMenu()
        for name in repos ?? [] {
            let item = menu.add("\(name) — \(repoBranches[name]?.current ?? "?")") {}
            item.isEnabled = false
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: branchButton.bounds.height + 4), in: branchButton)
    }

    /// Applies the status of a folder of repositories: the sum of theirs and each one's branch. There is no graph, as
    /// there is no one history.
    func applySeveral(_ event: GitEvent, _ names: [String]) {
        let changed = event.changes != changes || event.repoBranches ?? [:] != repoBranches || repos != names
        repos = names
        repoBranches = event.repoBranches ?? [:]
        changes = event.changes ?? []
        info = nil
        commits = []
        failureBar.show(nil)
        showError(nil)
        updateHeader()
        updateCommitButton()
        followWatches()
        layoutGraph()
        if changed { rebuildChanges() }
    }

    /// Pulls and pushes each repository that has something to move (the daemon skips the others).
    func syncSeveral() {
        guard let wid = worktreeId, !busy else { return }
        Task {
            let error = await GitSync.run(app, wid, [.pull, .push], title: String(localized: "Syncing…"))
            if let error { Banner.show(error, style: .error) }
            finish(String(localized: "Synced"), ok: error == nil, quiet: true, in: wid)
            reloadAll()
        }
    }
}
