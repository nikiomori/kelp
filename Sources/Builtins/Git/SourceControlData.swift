import AppKit
import Core
import DesignKit
import KelpKit

/// The workspace's status, history and remote state: git and CI as the daemon pushes them while the panel is on screen
/// (`gitWatch`, `ciWatch`), the graph read when the branches moved.
extension SourceControlController {
    func bind(_ wid: String?) {
        guard wid != worktreeId else { return }
        worktreeId = wid
        changes = []
        info = nil
        commits = []
        unpushed = []
        commitFiles = [:]
        openCommits = []
        limit = 200
        ciRuns = []; ciRow.show([], failure: nil)
        message.string = ""; messageChanged()
        rebuild()
        followWatches()
        apply(app.git[wid ?? ""])
    }

    /// Watched only while on screen: swapped out of the inspector, it reads no git.
    func followWatches() {
        let shown = view.window != nil ? worktreeId : nil
        gitWatch.key = shown
        ciWatch.key = info?.upstream != nil ? shown : nil   // no upstream: no CI line
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        followWatches()
        card.close()
    }

    /// Refresh, and after an action: read git again now rather than on the next file event.
    func reloadAll() { if let wid = worktreeId { app.watchAgain(.git, wid) } }

    /// What the daemon read: the lists, the header, and the graph when the branches moved.
    func apply(_ e: GitEvent?) {
        guard let e, e.worktree == worktreeId else { return }
        if let error = e.error {
            changes = []
            info = nil
            commits = []
            showError(error)
            updateHeader()
            rebuild()
            followWatches()
            return
        }
        guard let ch = e.changes, let br = e.branches else { return }
        let graphStale = br.head != info?.head || br.local != info?.local || br.remote != info?.remote || br.current != info?.current
            || br.ahead != info?.ahead || br.behind != info?.behind   // a push or fetch moved origin/…
        let changed = ch != changes || br != info
        // A push (or a publish) starts CI: look for its run now and for a while.
        let pushed = info.map { old in br.upstream != nil && br.current == old.current && (old.upstream == nil || (br.ahead ?? 0) < (old.ahead ?? 0)) } ?? false
        changes = ch
        info = br
        showError(nil)
        updateHeader(); updateCommitButton()
        showStats(ch.isEmpty ? nil : e.stats)   // the "+6 −2" on the first section
        followWatches()
        if pushed { app.watchAgain(.ci, e.worktree) }
        if graphStale || commits.isEmpty { Task { await loadGraph() } } else if changed { rebuildChanges() }
    }

    /// Nothing git can show here: say why instead of an empty commit box.
    private func showError(_ message: String?) {
        for v in [commitArea, separator, moreButton] { v?.isHidden = message != nil }
        outline.enclosingScrollView?.isHidden = message != nil
        empty.isHidden = message == nil
        layoutGraph()
        guard let message else { return }
        let notRepo = message.contains("not a git repository")
        let s = NSMutableAttributedString(string: notRepo ? String(localized: "Not a Git Repository") : String(localized: "Git Isn't Available"),
                                          attributes: [.font: NSFont.ui(13, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        s.append(NSAttributedString(string: "\n" + (notRepo ? String(localized: "This folder isn't under git version control.") : message),
                                    attributes: [.font: NSFont.ui(11), .foregroundColor: NSColor.tertiaryLabelColor]))
        if let fix = FixRecipes.fix(for: message) {   // the command that makes git work again, selectable
            s.append(NSAttributedString(string: String(localized: "\n\nFix it in Terminal:\n") + fix.command,
                                        attributes: [.font: NSFont.monospacedSystemFont(ofSize: TextSize.of(11), weight: .regular),
                                                     .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.paragraphSpacing = 4
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        empty.attributedStringValue = s
    }

    /// Shown again (another panel was on screen): watched again, and what changed meanwhile comes at once.
    override func viewDidAppear() { super.viewDidAppear(); followWatches() }

    /// The CI line under Commit, as the daemon pushes it (it looks again while a run goes on, and for a while after a
    /// push). No upstream, no gh / glab, no runs: no line.
    func applyCI(_ e: CIEvent?) {
        guard let e, e.worktree == worktreeId else { return }
        ciRuns = e.result?.runs ?? []
        let latest = CIRuns.latest(ciRuns)
        ciRow.show(latest, failure: nil)
        guard let failed = latest.first(where: \.failed) else { return }
        if let known = ciFailures[failed.id] { ciRow.show(latest, failure: known); return }
        let wid = e.worktree
        Task {
            ciFailures[failed.id] = await failurePlace(wid, run: failed.id)
            guard wid == worktreeId, CIRuns.latest(ciRuns) == latest else { return }
            ciRow.show(latest, failure: ciFailures[failed.id])
        }
    }

    /// "test › Run swift test": the first failed job and its failed step.
    private func failurePlace(_ wid: String, run: Int) async -> String? {
        let r = await app.tryCall(CIJobs(worktreeId: wid, run: run))
        guard let job = r.value?.first(where: \.failed) else { return nil }
        return ([job.name] + (job.steps.first(where: \.failed).map { [$0.name] } ?? [])).joined(separator: " › ")
    }

    /// The details live in the CI Runs panel (it opens the failed job's log by itself); without it, the run's page.
    func openCI() {
        if app.extensions.all.panels.contains(where: { $0.id == "ci" }) { app.workbench.showPanel("ci") }
        else if let run = CIRuns.latest(ciRuns).first(where: \.failed) ?? ciRuns.first { app.workbench.open(run.url) }
    }

    func loadGraph() async {
        guard let wid = worktreeId else { return }
        // Quiet: git failing shows in the panel from the status read before this; a graph that failed alone keeps the last one.
        let r = await app.quiet(GitGraph(id: wid, limit: limit), timeout: 60)
        guard wid == worktreeId else { return }
        if let r {
            let list = r.commits
            commits = list; more = r.more
            let before = unpushed
            unpushed = Git.unpushed(list, remotes: Set(info?.remote ?? []))
            let landed = list.filter { before.contains($0.hash) && !unpushed.contains($0.hash) }.reversed()
            landing = Dictionary(uniqueKeysWithValues: landed.enumerated().map { ($1.hash, Double(min($0, 12)) * 0.05) })
            let lanes = list.map { c in ([c.lane] + c.top.flatMap { $0 } + c.bottom.flatMap { $0 }).max() ?? 0 }.max() ?? 0
            graphWidth = GraphView.width(lanes: min(lanes + 1, GraphView.maxLanes))
        }
        loadingMore = false
        rebuild()
        // Landed once: a later rebuild (a commit unfolded) shows them as they are now.
        if !landing.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.landing = [:] } }
    }

    func pulseArrows() {
        for r in 0..<graphOutline.numberOfRows {
            (graphOutline.view(atColumn: 0, row: r, makeIfNecessary: false) as? CommitCell)?.pulse(syncing?.push == true)
        }
    }

    /// "+120 −30" for everything not committed yet; hovering splits it into code, tests and generated files.
    private func showStats(_ s: LineStats?) {
        defer { if !roots.isEmpty { outline.reloadData(forRowIndexes: [0], columnIndexes: [0]) } }   // the first section shows them
        guard let s, s.totalAdded + s.totalRemoved > 0 else { stats.isHidden = true; return }
        stats.isHidden = false
        stats.attributedStringValue = RowBadges.changes(s) ?? NSAttributedString()
        let names: [LineStats.Kind: String] = [.code: String(localized: "Code"), .tests: String(localized: "Tests"), .generated: String(localized: "Generated")]
        stats.toolTip = String(localized: "Not committed yet\n") + LineStats.Kind.allCases.compactMap { k in
            let a = s.added[k] ?? 0, r = s.removed[k] ?? 0
            return a + r == 0 ? nil : "\(names[k] ?? ""): +\(a) −\(r)"
        }.joined(separator: "\n")
    }

    func updateHeader() {
        bar.update(info, changes: changes.count, busy: busy)
        guard let info else { branchButton.title = ""; return }
        branchButton.title = info.current ?? String(localized: "Detached at \(info.head ?? "?")")
        if info.merging { branchButton.title += String(localized: " (Merging)") }
    }
}
