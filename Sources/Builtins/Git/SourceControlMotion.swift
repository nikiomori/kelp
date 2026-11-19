import AppKit
import Core
import DesignKit
import KelpKit

/// How git's work shows while it happens and when it's done: light on the panel's button, a shade running through the
/// arrows, a word on the button, and commits and files travelling to where they now belong.
extension SourceControlController {
    /// Called when `syncing` changed.
    func showWork() {
        if syncing != nil {
            finishes += 1   // work runs again, so a word still on show gives way
            confirmed = nil
            commitButton?.work = .running
        } else if commitButton?.work == .running {
            commitButton?.work = .none
        }
        updateCommitButton()
        pulseArrows()
        bar.flow(push: syncing?.push == true, pull: syncing?.pull == true)
    }

    /// Called when an action ended. The button says so for a moment, green, or red with a shake, because it's where the
    /// eye is. If the panel isn't on screen, a banner says it instead, unless it's `quiet` (a failure has already said
    /// why in a banner).
    func finish(_ word: String, ok: Bool, quiet: Bool, in wid: String) {
        guard view.window != nil, wid == worktreeId else {
            if ok, !quiet { Banner.show(word) }
            return
        }
        finishes += 1
        let ticket = finishes
        commitButton?.work = ok ? .done : .failed
        confirmed = ok ? word : nil
        updateCommitButton()
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.linger) { [weak self] in
            guard let self, finishes == ticket else { return }
            confirmed = nil
            commitButton?.work = .none
            updateCommitButton()
        }
    }

    // MARK: files

    private var changeShape: Set<String> { Set(changes.map { "\($0.staged) \($0.path)" }) }
    /// Called when files are about to be staged or discarded, so the next status that differs moves the rows.
    func noteChanges() { staging = changeShape }

    /// Fades discarded rows where they stand. The status then closes the gap, and a failed discard rebuilds them.
    func fadeRows(_ paths: Set<String>) {
        guard !Motion.reduced else { return }
        for rowIndex in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? FileCell,
                paths.contains(cell.path)
            else { continue }
            NSAnimationContext.runAnimationGroup {
                $0.duration = Motion.fast
                $0.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cell.animator().alphaValue = 0
            }
        }
    }

    /// Where the file rows stand while files are about to change; empty otherwise.
    func stagingPlaces() -> [String: NSPoint] {
        guard let was = staging, was != changeShape else { return [:] }
        staging = nil
        return outline.rowPlaces(fileKey)
    }

    func slideStaged(from places: [String: NSPoint]) { slideRows(outline, from: places, fileKey) }

    private func fileKey(_ row: Int) -> String? {
        (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell)?.path
    }

    /// After a reload, the rows that stayed travel from where they stood.
    private func slideRows(_ table: NSTableView, from places: [String: NSPoint], _ key: (Int) -> String?) {
        guard !places.isEmpty else { return }
        table.layoutSubtreeIfNeeded()
        table.enumerateAvailableRowViews { rowView, row in
            if let rowKey = key(row), let place = places[rowKey] { rowView.slide(from: place) }
        }
    }

    // MARK: commits

    /// `list` is what the graph is about to show. The commits on top of it that weren't there before come in one after
    /// another, oldest first. More than a screenful means another branch, not something that just happened.
    func noteArrivals(_ list: [GraphCommit], known: Set<String>) {
        guard !known.isEmpty else { return }
        let new = list.prefix { !known.contains($0.hash) }
        guard !new.isEmpty, new.count <= 12 else { return }
        arriving = Dictionary(
            uniqueKeysWithValues: new.reversed().enumerated().map { ($1.hash, Double($0) * Motion.stagger) })
    }

    func commitPlaces() -> [String: NSPoint] { graphOutline.rowPlaces(commitKey) }

    /// Moves the commits already there down to let the new ones in.
    func slideCommits(from places: [String: NSPoint]) { slideRows(graphOutline, from: places, commitKey) }

    private func commitKey(_ row: Int) -> String? {
        (graphOutline.view(atColumn: 0, row: row, makeIfNecessary: false) as? CommitCell)?.commitHash
    }
}
