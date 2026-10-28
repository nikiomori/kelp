import AppKit
import Core
import DesignKit

/// What the sidebar shows beside a folder: lines not committed yet, the branch's PR and its CI. Desks share their project's
/// folder, so the project row carries it; a workspace on its own branch (a worktree) carries its own. Every folder the
/// sidebar lists is watched: the daemon pushes its git when its files change, its PR (gh, once a minute) and its CI (while a
/// run goes, else every 2 minutes). The branch chip and its popover read the same CI for the folder on screen.
@MainActor @Observable
package final class RowBadges {
    private let app: AppModel
    /// Worktree id → changes / its branch's PR (observed through AppModel).
    var stats: [String: LineStats] { app.git.compactMapValues(\.stats) }
    var prs: [String: GitHub.PullRequest] { app.prs }
    @ObservationIgnored private var following: [WatchTopic: Set<String>] = [:]
    @ObservationIgnored private var states: [String: CIRuns.State] = [:]
    @ObservationIgnored private var branches: [String: BranchInfo] = [:]
    /// Folders whose CI passed while Kelp watched and that haven't been on screen since: the sidebar's quiet ✓.
    private(set) var unseen = Set<String>()
    /// Folders whose pass is on screen, since when: the branch chip's ✓, for a minute.
    private(set) var shown: [String: Date] = [:]

    init(app: AppModel) {
        self.app = app
        track(owner: self) { [weak self] in self?.wanted() ?? [:] } changed: { [weak self] in self?.follow($0) }
        track(owner: self) { [weak self] in self?.ciStates() ?? [:] } changed: { [weak self] in self?.landed($0) }
        track(owner: self) { [weak self] in self?.folder(of: app.workbench.workspaceId)?.id } changed: { [weak self] in
            if let id = $0, self?.unseen.remove(id) != nil { self?.show(id) }
        }
        track(owner: self) { app.git.compactMapValues(\.branches) } changed: { [weak self] in self?.pushes($0) }
    }

    /// Settings › Appearance › Changes and pull requests off: no git or PR is watched for the badges, gh isn't asked; CI
    /// beside folders off: only the folder on screen's CI, for the branch chip and its popover.
    private func wanted() -> [WatchTopic: Set<String>] {
        let s = app.settings
        let all = Set(app.repos.compactMap { folder(project: $0.id)?.id } + app.worktrees.compactMap { folder(workspace: $0.id)?.id })
        let badges = s.bool("workbench.sidebar.gitBadges") != false ? all : []
        var ci = s.bool("workbench.ci.sidebar") != false ? all : []
        if s.string("workbench.ci.branchChip") != "off" || s.bool("workbench.ci.popover") != false,
           let here = folder(of: app.workbench.workspaceId) { ci.insert(here.id) }
        return [.git: badges, .pr: badges, .ci: ci]
    }

    private func follow(_ now: [WatchTopic: Set<String>]) {
        for (topic, ids) in now {
            let had = following[topic] ?? []
            for id in ids.subtracting(had) { app.watch(topic, id) }
            for id in had.subtracting(ids) { app.unwatch(topic, id) }
        }
        following = now
    }

    /// The folder whose git, PR and CI a workspace shows: its own worktree's, or (a desk) its project's.
    func folder(of workspace: String?) -> Worktree? {
        app.worktree(workspace).flatMap { folder(workspace: $0.id) ?? folder(project: $0.repoId) }
    }

    /// The worktree whose folder a row stands for (nil: the row has none of its own).
    func folder(project id: String) -> Worktree? {
        let m = app
        guard let r = m.repo(id) else { return nil }
        return m.worktrees.first { $0.repoId == id && $0.path == r.path && !$0.archived }
    }
    func folder(workspace id: String) -> Worktree? {
        let m = app
        guard let w = m.worktree(id), !w.archived, w.path != m.repo(w.repoId)?.path else { return nil }
        return w
    }

    /// "+6 −2" in green and red (text shades: NSColor.textGreen); a side with nothing changed is left out ("+6", not "+6 −0").
    /// `compact`, for a row: "+21.7k" from ten thousand lines (generated files), the exact count left to its tooltip.
    package static func changes(_ s: LineStats?, compact: Bool = false) -> NSAttributedString? {
        guard let s, s.totalAdded + s.totalRemoved > 0 else { return nil }
        return changes(added: s.totalAdded, removed: s.totalRemoved, compact: compact)
    }
    package static func changes(added: Int, removed: Int, compact: Bool = false) -> NSAttributedString {
        let t = NSMutableAttributedString(), font = NSFont.uiDigits(11, weight: .regular)
        func n(_ v: Int) -> String {
            guard compact, v >= 10_000 else { return "\(v)" }
            let k = (Double(v) / 100).rounded() / 10
            return (k == k.rounded() ? String(Int(k)) : String(k)) + "k"
        }
        for (text, v, color) in [("+" + n(added), added, NSColor.textGreen), ("−" + n(removed), removed, NSColor.textRed)] where v > 0 {
            t.append(NSAttributedString(string: (t.length > 0 ? " " : "") + text, attributes: [.font: font, .foregroundColor: color]))
        }
        return t
    }

    /// "#12" in the PR's state colour; its checks are the folder's CI mark (`sidebarCI`, `chipCI`), the tooltip counts them.
    static func pr(_ p: GitHub.PullRequest?) -> (NSAttributedString, String)? {
        guard let p else { return nil }
        let n = p.number, state = p.isDraft ? "DRAFT" : p.state
        let color: NSColor = state == "DRAFT" ? .secondaryLabelColor : state == "MERGED" ? .textPurple : state == "CLOSED" ? .textRed : .textGreen
        let failed = p.checks.failed, pending = p.checks.pending, passed = p.checks.passed
        let t = NSAttributedString(string: "#\(n)", attributes: [.font: NSFont.uiDigits(11, weight: .medium), .foregroundColor: color])
        let checks = failed > 0 ? String(localized: "\(failed) checks failing") : pending > 0 ? String(localized: "\(pending) checks running")
            : passed > 0 ? String(localized: "checks passed") : String(localized: "no checks")
        let said = switch state {
        case "DRAFT": String(localized: "draft")
        case "MERGED": String(localized: "merged")
        case "CLOSED": String(localized: "closed")
        default: String(localized: "open")
        }
        return (t, String(localized: "Pull request #\(n) · \(said) · \(checks)") + "\n" + p.title)
    }
}

/// A folder's CI in one mark: what it says now, and a pass only until it's been seen (the sidebar) or for its first
/// minute on screen (the branch chip), so the ✓ tells you once and then gets out of the way.
extension RowBadges {
    /// Its runs and its PR's checks, the more pressing of the two (the checks lag a minute; the runs miss what isn't CI).
    func state(_ id: String) -> CIRuns.State? {
        [app.ci[id]?.result.flatMap { CIRuns.state($0.runs) }, app.prs[id].flatMap { CIRuns.state($0.checks) }].compactMap { $0 }.max()
    }
    /// Beside a folder in the sidebar (and the ⌃Tab switcher): a pass while it hasn't been on screen.
    func sidebarCI(_ id: String) -> CIRuns.State? {
        guard app.settings.bool("workbench.ci.sidebar") != false, let s = state(id) else { return nil }
        return s != .passed || unseen.contains(id) ? s : nil
    }
    /// Every folder's sidebar mark: the rows follow this, not each CI read.
    var sidebarMarks: [String: CIRuns.State] { Set(app.ci.keys).union(app.prs.keys).reduce(into: [:]) { $0[$1] = sidebarCI($1) } }
    /// On the branch chip: a pass for its first minute on screen.
    func chipCI(_ id: String) -> CIRuns.State? {
        guard let s = state(id) else { return nil }
        return s != .passed || unseen.contains(id) || shown[id] != nil ? s : nil
    }

    /// "CI: Failed · Tests, Deploy": what the mark says, and which workflows say it.
    func ciLine(_ id: String) -> String? {
        guard let s = state(id) else { return nil }
        let runs = CIRuns.latest(app.ci[id]?.result?.runs ?? []).filter {
            switch s {
            case .failed: $0.failed
            case .waiting: $0.status == "waiting"
            case .running: $0.status != "completed"
            case .passed: false
            }
        }
        let what = ([CIRunLook.words(s)] + (runs.isEmpty ? [] : [runs.map(\.workflow).joined(separator: ", ")])).joined(separator: " · ")
        return String(localized: "CI: \(what)")
    }

    /// CI Runs for the folder (it opens a failed job's log by itself), in its workspace; without the panel, the run's page.
    func openCI(_ id: String) {
        if folder(of: app.workbench.workspaceId)?.id != id { app.workbench.show(workspace: id) }
        if app.extensions.all.panels.contains(where: { $0.id == "ci" }) { app.workbench.showPanel("ci") }
        else if let runs = app.ci[id]?.result?.runs, let run = CIRuns.latest(runs).first(where: \.failed) ?? runs.first { app.workbench.open(run.url) }
    }

    private func ciStates() -> [String: CIRuns.State] {
        Set(app.ci.keys).union(app.prs.keys).reduce(into: [:]) { $0[$1] = state($1) }
    }

    /// A run that went from running to passed: on screen, the chip's ✓ for a minute; elsewhere, the sidebar's until you go there.
    /// Anything else (a new run, no CI) takes the ✓ away.
    private func landed(_ now: [String: CIRuns.State]) {
        let here = folder(of: app.workbench.workspaceId)?.id
        for (id, s) in now where s == .passed && (states[id] == .running || states[id] == .waiting) {
            if id == here { show(id) } else { unseen.insert(id) }
        }
        for id in unseen.union(shown.keys) where now[id] != .passed {
            unseen.remove(id)
            shown[id] = nil
        }
        states = now
    }

    private func show(_ id: String) {
        let at = Date()
        shown[id] = at
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            if self?.shown[id] == at { self?.shown[id] = nil }
        }
    }

    /// A push from anywhere (a terminal, an agent) starts CI: look for its run now, not on the next 2-minute read.
    private func pushes(_ now: [String: BranchInfo]) {
        for id in following[.ci] ?? [] { if let new = now[id], let old = branches[id], new.pushed(since: old) { app.watchAgain(.ci, id) } }
        branches = now
    }
}
