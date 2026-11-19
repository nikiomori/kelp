// Loading a diff: what the view asks git for, and the rows it shows from the answer.
import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit

/// The order a diff's reads and row builds come in. There is one read at a time, and an answer or rows for what is no
/// longer asked for are dropped. Only `load` and the builds change it.
struct DiffLoads {
    /// The read under way. There is one read at a time, and whatever asks meanwhile (git events, a click) makes one
    /// more read after it (`again`), not one each. A caller gets a diff read after it asked.
    var reading: Task<Void, Never>?
    var again = false
    /// Counts changes to what's asked for (another source or workspace), so a read of the old one drops its answer.
    var asking = 0
    /// Counts row builds, so a build that a newer build or a new diff overtook drops its rows.
    var builds = 0
    /// What the diff on screen was read from. A git event that leaves it as it was reads nothing.
    var basis: GitDiff.Basis?
    /// The `asking` whose diff is on screen, so a failed read of the same one keeps it.
    var shown: Int?
    /// How many reads ran so far, so tests can see a burst of events make one more read, not one each.
    var reads = 0
    /// How many diffs were coloured so far. An answer the same as the diff on screen isn't coloured again.
    var colourings = 0
}

extension DiffViewController {
    /// The agent whose turns a turn diff shows: the one text goes to without asking (`FileActions.agent`), else the
    /// newest.
    func turnAgent(_ wid: String) -> String? {
        (FileActions(app).agent(in: wid) ?? FileActions(app).agents(in: wid).last)?.id
    }

    func diffRequest() -> GitDiff {
        var query = request()
        query.ignoreSpace = hidesSpace ? true : nil
        return query
    }
    private func request() -> GitDiff {
        let id = worktreeId ?? ""
        if let single {
            return single.commit.map { GitDiff(id: id, source: .commit, file: single.file, commit: $0) }
                ?? GitDiff(id: id, source: single.source.wire, file: single.file)
        }
        switch sourcePicked {
        case .uncommitted, .unstaged, .staged, .branch, .tidy: return GitDiff(id: id, source: sourcePicked.wire)
        case .commit: return GitDiff(id: id, source: .commit, commit: commitHash ?? "HEAD")
        case .turn:
            // The agent whose turns the picker lists, not whichever agent has the focus by now.
            let listed = (turnPop.itemArray.first?.representedObject as? SessionTurns.Mark)?.session
            var turn = GitDiff(id: id, source: .turn, session: listed ?? turnAgent(id) ?? "")
            turn.turn = chosenTurn
            return turn
        }
    }

    func load() async {
        if let running = loads.reading {
            loads.again = true
            await running.value
            return
        }
        let task = Task {
            repeat {
                loads.again = false
                await loadOnce()
            } while loads.again
            loads.reading = nil   // no await since the last check, so a later caller starts a new read
        }
        loads.reading = task
        await task.value
    }

    private func loadOnce() async {
        loads.reads += 1
        guard let wid = worktreeId else {
            loads.builds += 1
            diffs = []
            rows = []
            table.reloadData()
            files.reloadData()
            return
        }
        // The first read of a tab waits with a spinner once it takes a second; a read over a diff on screen doesn't.
        if diffs.isEmpty, !empty.showing { loading.wait(String(localized: "Reading the changes…")) }
        if single == nil, sourcePicked == .commit, askCommit {
            askCommit = false   // before asking, so a load that starts while the question is up doesn't ask again
            // The user picked "a commit", so a banner says when git can't list them.
            let log = await app.call(GitLog(id: wid, all: true)) ?? []
            let commits = log.prefix(30).map { ("\($0.hash)  \($0.subject)", $0.hash) }
            if let hash = await pick(
                String(localized: "Review which commit?"), from: commits, action: String(localized: "Show"), width: 360)
            {
                commitHash = hash
            } else {
                sourcePicked = .uncommitted
                commitHash = nil
            }
        }
        askCommit = false
        let agent = turnAgent(wid)   // read once, because the focus can move during the reads below
        if single == nil, sourcePicked == .turn, agent == nil {
            loads.builds += 1
            diffs = []
            rows = []
            words = [:]
            files.reloadData()
            table.reloadData()
            showState(error: nil, nothing: String(localized: "No agent on this screen"))
            return
        }
        if single == nil { await readTurns(sourcePicked == .turn ? agent : nil) }
        let asked = loads.asking, request = diffRequest()
        loads.basis = request.basis(app.latest(GitEvent.self, app.gitKey(wid)))
        let result = await app.tryCall(request)
        // A failed read of the diff on screen keeps it, and says so over it.
        if let error = result.error, !diffs.isEmpty, loads.shown == asked, asked == loads.asking {
            return failureBar.show(error)
        }
        let newDiffs = result.value ?? []
        var ch: [FileChange] = [], cm: [DiffComment] = []
        // The files' letters and the comments; when the diff failed, its error already says so.
        if single == nil, result.error == nil {
            // The letters come as pushed for this workspace (a review tab watches it), or else are asked for.
            if let pushed = app.latest(GitEvent.self, app.gitKey(wid))?.changes {
                ch = pushed
            } else {
                ch = await app.quiet(GitStatus(id: wid)) ?? []
            }
            // On a past commit's diff, only that commit's comments.
            cm = (await app.quiet(CommentList(id: wid)) ?? []).filter { [on = shownCommit] in $0.isOn(on) }
        }
        // The diffs are compared once, off the main thread, because a big diff (a lock file beside an agent's edit)
        // is megabytes.
        let shown = diffs, same = await Task.detached { newDiffs == shown }.value
        if !same { opened = [:] }   // lines opened between changes may have moved
        let grammars = same ? [:] : DiffColors.grammars(newDiffs)   // the same diff keeps its colours
        if !same { loads.colourings += 1 }
        async let parsed = Task.detached { same ? nil : DiffColors.spans(newDiffs, grammars: grammars) }.value
        let layout = sideBySide, built = await buildRows(newDiffs, cm, sideBySide: layout)
        let printed = await Task.detached {
            Dictionary(newDiffs.map { ($0.path, ViewedFiles.print($0)) }) { a, _ in a }
        }.value
        let spans = await parsed
        await loading.settled()   // so the rows don't come up under a wait that has only just appeared
        // Rows, cell tags and the hunk buttons all index `diffs`, so they change together, once every answer is in.
        guard asked == loads.asking, wid == worktreeId else { return }
        loads.builds += 1   // rows that a layout change is still building are the old diff's
        loads.shown = asked
        if let spans {
            position.stringValue = ""
            syntax = spans
        }   // "Change 3 of 17" counted the old diff
        diffs = newDiffs
        viewed.prints = printed
        changes = ch
        notes.saved = cm
        readViewed()
        (rows, words) = built
        placeDraft()
        files.reloadData()
        reloadKeepingDraft()
        if !find.needle.isEmpty { search(find.needle, step: false) }
        if layout != sideBySide { rebuildRows() }   // the layout changed while these were built
        showState(error: result.error)
    }

    /// Shows what the diff's room says when it has no rows, as every panel does: git's error with Try Again, or
    /// `nothing` ("No Changes") for an empty diff. The bar counts files only when there are some, not "0 files".
    func showState(error: String?, nothing: String = String(localized: "No Changes")) {
        loading.show(nil)
        failureBar.show(nil)
        if let error {
            empty.showError(
                String(localized: "Couldn’t Read the Changes"), text: error, fix: FixRecipes.fix(for: error)?.command,
                buttons: [tryAgain])
        } else {
            empty.show(diffs.isEmpty ? nothing : nil, symbol: "plus.forwardslash.minus")
        }
        status.stringValue = error == nil && !diffs.isEmpty ? statusText() : ""
    }
}
