import AppKit
import Core
import DesignKit
import KelpKit

/// The workspace's status, history and remote state. Git and CI come as the daemon pushes them while the panel is on
/// screen (`gitWatch`, `ciWatch`), and the graph is read when the branches moved.
extension SourceControlController {
    func bind(_ wid: String?) {
        guard wid != worktreeId else { return }
        if let old = worktreeId {
            drafts[old] = message.string.isEmpty ? nil : message.string
            seen[old] = Seen(
                changes: changes, info: graphInfo, commits: commits, unpushed: unpushed, more: more, limit: limit)
        }
        worktreeId = wid
        failureBar.show(nil)
        loading.show(nil)
        showNoProject(wid == nil)
        let back = wid.flatMap { seen[$0] }
        changes = back?.changes ?? []
        info = back?.info
        graphInfo = back?.info
        commits = back?.commits ?? []
        unpushed = back?.unpushed ?? []
        more = back?.more ?? false
        limit = back?.limit ?? 200
        commitFiles = [:]
        openCommits = []
        ciRuns = []
        ciRow.show([], failure: nil)
        message.string = wid.flatMap { drafts[$0] } ?? ""
        messageChanged()
        showAgentCommit()
        finishes += 1   // what the button was saying about the last workspace isn't about this one
        confirmed = nil
        commitButton?.work = .none
        showWork()
        updateHeader()
        rebuild()
        followWatches()
        apply(app.latest(GitEvent.self, gitKey ?? ""))
        awaitFirstRead()
    }

    /// While git's first answer for this folder is on its way, the list's place says so once that takes a second, so
    /// an empty list isn't read as no changes.
    private func awaitFirstRead() {
        guard view.window != nil, let gitKey, app.latest(GitEvent.self, gitKey) == nil else { return }
        loading.wait(String(localized: "Reading the changes…"))
    }

    /// The key that git and CI are watched and pushed under: the folder, which other workspaces may share.
    var gitKey: String? { worktreeId.map(app.gitKey) }

    /// Watches only while the panel is on screen, so when it's swapped out of the inspector it reads no git.
    func followWatches() {
        let shown = view.window != nil ? gitKey : nil
        gitWatch.key = shown
        ciWatch.key = info?.upstream != nil ? shown : nil   // with no upstream there is no CI line
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        followWatches()
        card.close()
    }

    /// Refresh, and what runs after an action: reads git again now rather than on the next file event.
    func reloadAll() { if let gitKey { app.watchAgain(.git, gitKey) } }

    /// Applies what the daemon read: the lists, the header, and the graph when the branches moved.
    func apply(_ event: GitEvent?) {
        guard let event, event.worktree == gitKey else { return }
        if loading.showing {   // a wait on screen stays its moment, and then gives way to the answer
            Task {
                await loading.settled()
                loading.show(nil)
                apply(app.latest(GitEvent.self, gitKey ?? ""))
            }
            return
        }
        loading.show(nil)
        if let error = event.error {
            // What git read here before stays, under a line that says why it couldn't be read again. A folder that is
            // no repository any more has nothing to keep.
            if info != nil, !error.contains("not a git repository") {
                failureBar.show(error)
                return followWatches()
            }
            failureBar.show(nil)
            changes = []
            info = nil
            commits = []
            graphInfo = nil
            showError(error)
            updateHeader()
            rebuild()
            followWatches()
            return
        }
        guard let ch = event.changes, let br = event.branches else { return }
        let graphStale =
            br.head != info?.head || br.local != info?.local || br.remote != info?.remote || br.current != info?.current
            || br.ahead != info?.ahead || br.behind != info?.behind   // a push or fetch moved origin/…
        let changed = ch != changes || br != info
        // A push (or a publish) starts CI, so its run is looked for now and for a while.
        let pushed = info.map { br.pushed(since: $0) } ?? false
        changes = ch
        info = br
        failureBar.show(nil)
        showError(nil)
        updateHeader()
        updateCommitButton()
        showStats(ch.isEmpty ? nil : event.stats)   // the "+6 −2" on the first section
        followWatches()
        if pushed { app.watchAgain(.ci, event.worktree) }
        if graphStale || commits.isEmpty { Task { await loadGraph() } } else if changed { rebuildChanges() }
    }

    private func hideBox(_ hide: Bool) {
        for v in [commitArea, separator, moreButton] { v?.isHidden = hide }
        outline.enclosingScrollView?.isHidden = hide
        layoutGraph()
    }

    /// With no project on screen there is no branch to name and nothing to commit, so no header or box is left empty.
    func showNoProject(_ none: Bool) {
        hideBox(none)
        headerBar?.isHidden = none
        empty.show(
            none ? String(localized: "No Project") : nil, symbol: "folder",
            text: String(localized: "A project's changes and history show here."))
    }

    /// When git can show nothing here, says why instead of showing an empty commit box.
    private func showError(_ message: String?) {
        hideBox(message != nil)
        if message == nil { empty.show(nil) }
        guard let message else { return }
        let notRepo = message.contains("not a git repository")
        let away = message.hasPrefix("Can't reach ")   // the daemon's words for an unreachable remote host
        // The command that makes git work again, which the user can select.
        empty.showError(
            notRepo
                ? String(localized: "Not a Git Repository")
                : away ? String(localized: "Can't Reach the Server") : String(localized: "Git Isn't Available"),
            text: notRepo ? String(localized: "This folder isn't under git version control.") : message,
            fix: FixRecipes.fix(for: message)?.command)
    }

    /// Called when the panel shows again after another panel was on screen. It is watched again, and what changed
    /// meanwhile comes at once.
    override func viewDidAppear() {
        super.viewDidAppear()
        followWatches()
        awaitFirstRead()
    }

    /// The CI line under Commit, as the daemon pushes it (it looks again while a run goes on, and for a while after a
    /// push). With no upstream, no gh / glab, or no runs, there is no line.
    func applyCI(_ event: CIEvent?) {
        guard let event, event.worktree == gitKey else { return }
        ciRuns = event.result?.runs ?? []
        let latest = CIRuns.latest(ciRuns)
        ciRow.show(latest, failure: nil)
        guard let failed = latest.first(where: \.failed) else { return }
        if let known = ciFailures[failed.id] {
            ciRow.show(latest, failure: known)
            return
        }
        let wid = event.worktree
        Task {
            ciFailures[failed.id] = await failurePlace(wid, run: failed.id)
            guard wid == worktreeId, CIRuns.latest(ciRuns) == latest else { return }
            ciRow.show(latest, failure: ciFailures[failed.id])
        }
    }

    /// The first failed job and its failed step: "test › Run swift test".
    private func failurePlace(_ wid: String, run: Int) async -> String? {
        let result = await app.tryCall(CIJobs(worktreeId: wid, run: run))
        guard let job = result.value?.first(where: \.failed) else { return nil }
        return ([job.name] + (job.steps.first(where: \.failed).map { [$0.name] } ?? [])).joined(separator: " › ")
    }

    /// Opens the details in the CI Runs panel, which opens the failed job's log by itself; without the panel, the
    /// run's page.
    func openCI() { worktreeId.map(RowMarks.of(app).openCI) }

    /// The graph's Refresh. It answers the click at once, because reading the graph can take a while.
    func refreshGraph() async {
        graphBar.busy = true
        await loadGraph()
        graphBar.busy = false
    }

    func loadGraph() async {
        guard let wid = worktreeId else { return }
        let asked = info
        // Read quietly, because git failing shows in the panel from the status read before this. A graph that failed
        // alone keeps the last one.
        let graph = await app.quiet(GitGraph(id: wid, limit: limit), timeout: 60)
        guard wid == worktreeId else { return }
        if let graph {
            graphInfo = asked
            let list = graph.commits, known = Set(commits.map(\.hash))
            noteArrivals(list, known: known)
            commits = list
            more = graph.more
            let before = unpushed
            unpushed = Git.unpushed(list, remotes: Set(info?.remote ?? []))
            let landed = list.filter { before.contains($0.hash) && !unpushed.contains($0.hash) }.reversed()
            landing = Dictionary(
                uniqueKeysWithValues: landed.enumerated().map { ($1.hash, Double(min($0, 12)) * Motion.stagger) })
        }
        loadingMore = false
        let places = arriving.isEmpty ? [:] : commitPlaces()
        rebuild()
        slideCommits(from: places)
        // The commits land once, so a later rebuild (a commit unfolded) shows them as they are now.
        if !landing.isEmpty || !arriving.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.linger) { [weak self] in
                self?.landing = [:]
                self?.arriving = [:]
            }
        }
    }

    func pulseArrows() {
        for r in 0..<graphOutline.numberOfRows {
            (graphOutline.view(atColumn: 0, row: r, makeIfNecessary: false) as? CommitCell)?.pulse(
                syncing?.push == true)
        }
    }

    /// Shows "+120 −30" for everything not committed yet; hovering splits it into code, tests and generated files.
    private func showStats(_ lineStats: LineStats?) {
        // The first section shows the stats.
        defer { if !roots.isEmpty { outline.reloadData(forRowIndexes: [0], columnIndexes: [0]) } }
        guard let lineStats, lineStats.totalAdded + lineStats.totalRemoved > 0 else {
            stats.isHidden = true
            return
        }
        stats.isHidden = false
        stats.attributedStringValue = GitFolders.changes(lineStats) ?? NSAttributedString()
        let names: [LineStats.Kind: String] = [
            .code: String(localized: "Code"), .tests: String(localized: "Tests"),
            .generated: String(localized: "Generated")
        ]
        stats.toolTip =
            String(localized: "Not committed yet\n")
            + LineStats.Kind.allCases.compactMap { kind in
                let added = lineStats.added[kind] ?? 0, removed = lineStats.removed[kind] ?? 0
                return added + removed == 0 ? nil : "\(names[kind] ?? ""): +\(added) −\(removed)"
            }.joined(separator: "\n")
    }

    func updateHeader() {
        bar.update(info, changes: changes.count, busy: busy)
        guard let info else {
            branchButton.title = ""
            return
        }
        branchButton.title = info.current ?? String(localized: "Detached at \(info.head ?? "?")")
        if info.merging { branchButton.title += String(localized: " (Merging)") }
    }
}
