import AppKit
import Core
import DesignKit
import KelpKit

/// What Git marks beside a folder in the sidebar, the ⌃Tab switcher and the window bar (`FolderCI`): its CI, its
/// branch's PR (`PullRequests`), and a PR that merged (`MergedPR`). Every folder the sidebar lists is watched for CI
/// (while a run goes, else every 2 minutes) and for its PR (gh, once a minute); the branch chip and its popover read
/// the same CI for the folder on screen, a hover card the PR of its folder. The app's one, as a part (`AppModel.part`).
@MainActor @Observable
final class RowMarks {
    static func of(_ app: AppModel) -> RowMarks { app.part { RowMarks(app: app) } }

    private let app: AppModel
    var prs: [String: GitHub.PullRequest] { app.latest(PREvent.self).byKey.compactMapValues(\.pr) }
    @ObservationIgnored private var following: [WatchTopic: Set<String>] = [:]
    /// The folder whose hover card is open: its PR is read while it is, beside the folders' badges or without them.
    var carded: String?
    @ObservationIgnored private var readPRs: [String: GitHub.PullRequest] = [:]
    @ObservationIgnored private var states: [String: CIRuns.State] = [:]
    @ObservationIgnored private var branches: [String: BranchInfo] = [:]
    /// Folders whose CI passed while Kelp watched and that haven't been on screen since: the sidebar's quiet ✓.
    private(set) var unseen = Set<String>()
    /// Folders whose pass is on screen, since when: the branch chip's ✓, for a minute.
    private(set) var shown: [String: Date] = [:]

    init(app: AppModel) {
        self.app = app
        track(owner: self) { [weak self] in
            self?.wanted() ?? [:]
        } changed: { [weak self] in
            self?.follow($0)
        }
        track(owner: self) { [weak self] in
            self?.ciStates() ?? [:]
        } changed: { [weak self] in
            self?.landed($0)
        }
        track(owner: self) {
            app.gitFolder(of: app.workbench.workspaceId)?.id
        } changed: { [weak self] in
            if let id = $0, self?.unseen.remove(id) != nil { self?.show(id) }
        }
        track(owner: self) {
            app.latest(GitEvent.self).byKey.compactMapValues(\.branches)
        } changed: { [weak self] in
            self?.pushes($0)
        }
        track(owner: self) {
            app.latest(PREvent.self).byKey.compactMapValues(\.pr)
        } changed: { [weak self] in
            self?.prsRead($0)
        }
    }

    private func prsRead(_ now: [String: GitHub.PullRequest]) {
        for id in MergedPR.justMerged(now, was: readPRs).keys { app.worktree(id).map(MergedPR(app: app).tell) }
        readPRs = readPRs.merging(now) { $1 }   // a folder not read for a moment is still the same PR's
    }

    /// CI beside folders off: only the folder on screen's CI, for the branch chip and its popover. Settings ›
    /// Appearance › Changes and pull requests off: only the PR of a folder whose card is open, gh isn't asked for the
    /// rest. Git turned off (no marks from it): none.
    private func wanted() -> [WatchTopic: Set<String>] {
        let settings = app.settings
        guard app.extensions.all.ci != nil else { return [:] }
        var ci = settings[SettingKeys.ciSidebar] ? app.gitFolders : []
        if settings[SettingKeys.ciBranchChip] != "off" || settings[SettingKeys.ciPopover],
            let here = app.gitFolder(of: app.workbench.workspaceId)
        {
            ci.insert(here.id)
        }
        let prs = (settings[SettingKeys.gitBadges] ? app.gitFolders : []).union(carded.map { [$0] } ?? [])
        return [.ci: ci, .pr: prs]
    }

    private func follow(_ now: [WatchTopic: Set<String>]) {
        for topic in Set(now.keys).union(following.keys) {
            let ids = now[topic] ?? [], had = following[topic] ?? []
            for id in ids.subtracting(had) { app.watch(topic, id) }
            for id in had.subtracting(ids) { app.unwatch(topic, id) }
        }
        following = now
    }
}

/// A folder's CI in one mark: what it says now, and a pass only until it's been seen (the sidebar) or for its first
/// minute on screen (the branch chip), so the ✓ tells you once and then gets out of the way.
extension RowMarks {
    /// Its runs and its PR's checks, the more pressing of the two (the checks lag a minute; the runs miss what isn't CI).
    func state(_ id: String) -> CIRuns.State? {
        let ci = app.latest(CIEvent.self, id)?.result.flatMap { CIRuns.state($0.runs) }
        return [ci, app.latest(PREvent.self, id)?.pr.flatMap { CIRuns.state($0.checks) }].compactMap { $0 }.max()
    }
    /// Beside a folder in the sidebar (and the ⌃Tab switcher): a pass while it hasn't been on screen.
    func sidebarCI(_ id: String) -> CIRuns.State? {
        guard app.settings[SettingKeys.ciSidebar], let ciState = state(id) else { return nil }
        return ciState != .passed || unseen.contains(id) ? ciState : nil
    }
    /// Every folder's sidebar mark: the rows follow this, not each CI read.
    var sidebarMarks: [String: CIRuns.State] {
        Set(app.latest(CIEvent.self).byKey.keys).union(prs.keys).reduce(into: [:]) { $0[$1] = sidebarCI($1) }
    }
    /// On the branch chip: a pass for its first minute on screen.
    func chipCI(_ id: String) -> CIRuns.State? {
        guard let ciState = state(id) else { return nil }
        return ciState != .passed || unseen.contains(id) || shown[id] != nil ? ciState : nil
    }
    /// Where the chip shows it (Settings › CI on the branch chip): in place of the branch glyph, after the counts, or
    /// not at all.
    func chip(_ id: String) -> (state: CIRuns.State, atEnd: Bool)? {
        let place = app.settings[SettingKeys.ciBranchChip]
        guard place != "off", let ciState = chipCI(id) else { return nil }
        return (ciState, place == "end")
    }

    /// "CI: Failed · Tests, Deploy": what the mark says, and which workflows say it.
    func ciLine(_ id: String) -> String? {
        guard let ciState = state(id) else { return nil }
        let runs = CIRuns.latest(app.latest(CIEvent.self, id)?.result?.runs ?? []).filter {
            switch ciState {
            case .failed: $0.failed
            case .waiting: $0.status == "waiting"
            case .running: $0.status != "completed"
            case .passed: false
            }
        }
        let what = ([CIRunLook.words(ciState)] + (runs.isEmpty ? [] : [runs.map(\.workflow).joined(separator: ", ")]))
            .joined(
                separator: " · ")
        return String(localized: "CI: \(what)")
    }

    /// CI Runs for the folder (it opens a failed job's log by itself), in its workspace; without the panel, the run's page.
    func openCI(_ id: String) {
        if app.gitFolder(of: app.workbench.workspaceId)?.id != id || app.workbench.page != nil {
            app.workbench.show(workspace: id)
        }
        if let panel = app.extensions.all.panels.first(where: { $0.role == .checks }) {
            app.workbench.showPanel(panel.id)
        } else if let runs = app.latest(CIEvent.self, id)?.result?.runs,
            let run = CIRuns.latest(runs).first(where: \.failed) ?? runs.first
        {
            app.workbench.open(run.url)
        }
    }

    /// The branch chip's menu: Create Pull Request while the branch has none, and where its CI shows.
    func menuItems(_ menu: NSMenu, worktree: String?) {
        PullRequests.menuItems(menu, worktree: worktree, app)
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addChoices(SettingKeys.ciBranchChip, app, heading: String(localized: "CI on the Chip"))
        menu.addToggle(SettingKeys.ciPopover, app, title: String(localized: "CI in the Popover"))
        menu.addItem(.separator())
        menu.addSettingsLink(String(localized: "CI Settings…"), section: "git", group: "CI", app)
    }

    private func ciStates() -> [String: CIRuns.State] {
        Set(app.latest(CIEvent.self).byKey.keys).union(prs.keys).reduce(into: [:]) { $0[$1] = state($1) }
    }

    /// A run that went from running to passed: on screen, the chip's ✓ for a minute; elsewhere, the sidebar's until you go there.
    /// Anything else (a new run, no CI) takes the ✓ away.
    private func landed(_ now: [String: CIRuns.State]) {
        let here = app.gitFolder(of: app.workbench.workspaceId)?.id
        for (id, ciState) in now where ciState == .passed && (states[id] == .running || states[id] == .waiting) {
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
        for id in following[.ci] ?? [] {
            if let new = now[id], let old = branches[id], new.pushed(since: old) { app.watchAgain(.ci, id) }
        }
        branches = now
    }
}

extension CIRunLook {
    /// A branch's CI in one word, for tooltips and VoiceOver.
    static func words(_ state: CIRuns.State) -> String {
        switch state {
        case .passed: String(localized: "Succeeded")
        case .running: String(localized: "Running")
        case .waiting: String(localized: "Waiting for approval")
        case .failed: String(localized: "Failed")
        }
    }
}
