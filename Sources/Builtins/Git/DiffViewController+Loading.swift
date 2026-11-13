// Loading a diff: what the view asks git for, and the rows it shows from the answer.
import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// The order a diff's reads and row builds come in: one read at a time, and an answer or rows for what's no longer asked
/// are dropped. Only `load` and the builds change it.
struct DiffLoads {
    /// One read at a time: what asks meanwhile (git events, a click) makes one more read after it (`again`), not one
    /// each. A caller gets a diff read after it asked.
    var reading: Task<Void, Never>?
    var again = false
    /// Counts changes to what's asked (another source or workspace): a read of the old one drops its answer.
    var asking = 0
    /// Counts row builds: one that a newer build or a new diff overtook drops its rows.
    var builds = 0
    /// What the diff on screen was read from: a git event that leaves it as it was reads nothing.
    var basis: GitDiff.Basis?
    /// Reads so far: tests see a burst of events make one more, not one each.
    var reads = 0
}

extension DiffViewController {
    func diffRequest() -> GitDiff {
        var query = request()
        query.ignoreSpace = hidesSpace ? true : nil
        return query
    }
    private func request() -> GitDiff {
        let id = worktreeId ?? ""
        if let single {
            return single.commit.map { GitDiff(id: id, source: "commit", file: single.file, commit: $0) }
                ?? GitDiff(id: id, source: single.source.wire, file: single.file)
        }
        switch sourcePicked {
        case .uncommitted, .unstaged, .staged, .branch, .tidy: return GitDiff(id: id, source: sourcePicked.wire)
        case .commit: return GitDiff(id: id, source: "commit", commit: commitHash ?? "HEAD")
        case .turn:
            // The agent whose turns the picker lists, not whichever has the focus by now.
            let listed = (turnPop.itemArray.first?.representedObject as? SessionTurns.Mark)?.session
            var turn = GitDiff(id: id, source: "turn", session: listed ?? FileActions(app).targetAgent?.id ?? "")
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
            loads.reading = nil   // with the last check: no await between, so a later caller starts a new one
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
        if single == nil, sourcePicked == .commit, askCommit {
            askCommit = false   // before asking: a load that starts while the question is up doesn't ask again
            let log = await app.call(GitLog(id: wid, all: true)) ?? []   // the user picked "a commit": a banner if git can't list them
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
        let agent = FileActions(app).targetAgent?.id   // read once: the focus can move during the reads below
        if single == nil, sourcePicked == .turn, agent == nil {
            loads.builds += 1
            diffs = []
            rows = []
            words = [:]
            files.reloadData()
            table.reloadData()
            status.stringValue = String(localized: "No agent on this screen")
            return
        }
        if single == nil { await readTurns(sourcePicked == .turn ? agent : nil) }
        let asked = loads.asking, request = diffRequest()
        loads.basis = request.basis(app.latest(GitEvent.self, wid))
        let result = await app.tryCall(request)
        let newDiffs = result.value ?? []
        var ch: [FileChange] = [], cm: [DiffComment] = []
        if single == nil, result.error == nil {   // the files' letters and the comments: the diff above already said what failed
            // The letters as pushed for this workspace (a review tab watches it), else asked.
            if let pushed = app.latest(GitEvent.self, wid)?.changes {
                ch = pushed
            } else {
                ch = await app.quiet(GitStatus(id: wid)) ?? []
            }
            cm = (await app.quiet(CommentList(id: wid)) ?? []).filter { [on = shownCommit] in $0.isOn(on) }   // a past commit's on its diff
        }
        if newDiffs != diffs { opened = [:] }   // lines opened between changes may have moved
        let grammars = newDiffs == diffs ? [:] : DiffColors.grammars(newDiffs)   // the same diff keeps its colours
        async let parsed = Task.detached { DiffColors.spans(newDiffs, grammars: grammars) }.value
        let layout = sideBySide, built = await buildRows(newDiffs, cm, sideBySide: layout)
        let printed = await Task.detached {
            Dictionary(newDiffs.map { ($0.path, ViewedFiles.print($0)) }) { a, _ in a }
        }.value
        let spans = await parsed
        // Rows, cell tags and the hunk buttons index `diffs`: they change together, once every answer is in.
        guard asked == loads.asking, wid == worktreeId else { return }
        loads.builds += 1   // rows a layout change is still building are the old diff's
        if newDiffs != diffs {
            position.stringValue = ""
            syntax = spans
        }   // "Change 3 of 17" counted another diff
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
        if let error = result.error {
            status.stringValue = error
            return
        }   // why there's nothing, not "0 files"
        status.stringValue = statusText()
    }
}
