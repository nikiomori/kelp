// Loading a diff: what the view asks git for, and the rows it shows from the answer.
import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

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
                ?? GitDiff(id: id, source: single.source, file: single.file)
        }
        switch source.indexOfSelectedItem {
        case 1: return GitDiff(id: id, source: "unstaged")
        case 2: return GitDiff(id: id, source: "staged")
        case 3: return GitDiff(id: id, source: "branch")
        case 4: return GitDiff(id: id, source: "commit", commit: commitHash ?? "HEAD")
        case 5:
            // The agent whose turns the picker lists, not whichever has the focus by now.
            let listed = (turnPop.itemArray.first?.representedObject as? SessionTurns.Mark)?.session
            var turn = GitDiff(id: id, source: "turn", session: listed ?? FileActions(app).targetAgent?.id ?? "")
            turn.turn = chosenTurn
            return turn
        default: return GitDiff(id: id, source: "all")
        }
    }

    func load() async {
        if let running = reading {
            readAgain = true
            await running.value
            return
        }
        let task = Task {
            repeat {
                readAgain = false
                await loadOnce()
            } while readAgain
            reading = nil   // with the last check: no await between, so a later caller starts a new one
        }
        reading = task
        await task.value
    }

    private func loadOnce() async {
        reads += 1
        guard let wid = worktreeId else {
            builds += 1
            diffs = []
            rows = []
            table.reloadData()
            files.reloadData()
            return
        }
        if single == nil, source.indexOfSelectedItem == 4, askCommit {
            askCommit = false   // before asking: a load that starts while the question is up doesn't ask again
            let log = await app.call(GitLog(id: wid, all: true)) ?? []   // the user picked "a commit": a banner if git can't list them
            let menu = NSMenu()
            for commit in log.prefix(30) {
                let item = menu.addItem(withTitle: "\(commit.hash)  \(commit.subject)", action: nil, keyEquivalent: "")
                item.representedObject = commit.hash
            }
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
            pop.menu = menu
            let alert = NSAlert()
            alert.messageText = String(localized: "Review which commit?")
            alert.accessoryView = pop
            alert.addButton(withTitle: String(localized: "Show"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if await runSheet(alert) == .alertFirstButtonReturn {
                commitHash = pop.selectedItem?.representedObject as? String
            } else {
                source.selectItem(at: 0)
                commitHash = nil
            }
        }
        askCommit = false
        let agent = FileActions(app).targetAgent?.id   // read once: the focus can move during the reads below
        if single == nil, source.indexOfSelectedItem == 5, agent == nil {
            builds += 1
            diffs = []
            rows = []
            words = [:]
            files.reloadData()
            table.reloadData()
            status.stringValue = String(localized: "No agent on this screen")
            return
        }
        if single == nil { await readTurns(source.indexOfSelectedItem == 5 ? agent : nil) }
        let asked = asking, request = diffRequest()
        basis = request.basis(app.latest(GitEvent.self, wid))
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
        guard asked == asking, wid == worktreeId else { return }
        builds += 1   // rows a layout change is still building are the old diff's
        if newDiffs != diffs {
            position.stringValue = ""
            syntax = spans
        }   // "Change 3 of 17" counted another diff
        diffs = newDiffs
        prints = printed
        changes = ch
        comments = cm
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
