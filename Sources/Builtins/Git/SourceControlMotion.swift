import AppKit
import Core
import DesignKit
import KelpKit

/// How git's work shows while it happens and when it's done: light on the panel's button, a shade running through the
/// arrows, a word on the button, and commits and files travelling to where they now belong.
extension SourceControlController {
    /// `syncing` changed.
    func showWork() {
        if syncing != nil {
            finishes += 1   // work again: a word still on show gives way
            confirmed = nil
            commitButton?.work = .running
        } else if commitButton?.work == .running {
            commitButton?.work = .none
        }
        updateCommitButton()
        pulseArrows()
        bar.flow(push: syncing?.push == true, pull: syncing?.pull == true)
    }

    /// An action ended. The button stays for a moment to say so, green or red with a shake: it's where the eye is. If the
    /// panel isn't on screen, a banner says it instead, unless it's `quiet` (a failure has already said why in one).
    func finish(_ word: String, ok: Bool, quiet: Bool) {
        guard view.window != nil else {
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

    /// Where the file rows stand, while staged files are about to change sections; nil-like empty otherwise.
    func stagingPlaces() -> [String: NSPoint] {
        guard let was = staging, was != Set(changes.filter(\.staged).map(\.path)) else { return [:] }
        staging = nil
        var places: [String: NSPoint] = [:]
        for r in 0..<outline.numberOfRows {
            if let cell = outline.view(atColumn: 0, row: r, makeIfNecessary: false) as? FileCell { places[cell.path] = cell.placeInWindow }
        }
        return places
    }

    func slideStaged(from places: [String: NSPoint]) {
        guard !places.isEmpty else { return }
        outline.layoutSubtreeIfNeeded()
        for r in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: r, makeIfNecessary: false) as? FileCell, let place = places[cell.path] else { continue }
            cell.slide(from: place)
        }
    }

    // MARK: commits

    /// `list` is what the graph is about to show: the commits on top of it that weren't there come in one after another,
    /// oldest first. More than a screenful is another branch, not something that just happened.
    func noteArrivals(_ list: [GraphCommit], known: Set<String>) {
        guard !known.isEmpty else { return }
        let new = list.prefix { !known.contains($0.hash) }
        guard !new.isEmpty, new.count <= 12 else { return }
        arriving = Dictionary(uniqueKeysWithValues: new.reversed().enumerated().map { ($1.hash, Double($0) * 0.05) })
    }

    func commitPlaces() -> [String: NSPoint] {
        var places: [String: NSPoint] = [:]
        for r in 0..<graphOutline.numberOfRows {
            if let cell = graphOutline.view(atColumn: 0, row: r, makeIfNecessary: false) as? CommitCell { places[cell.commitHash] = cell.placeInWindow }
        }
        return places
    }

    /// The commits already there move down to let the new ones in.
    func slideCommits(from places: [String: NSPoint]) {
        guard !places.isEmpty else { return }
        graphOutline.layoutSubtreeIfNeeded()
        for r in 0..<graphOutline.numberOfRows {
            let cell = graphOutline.view(atColumn: 0, row: r, makeIfNecessary: false) as? CommitCell
            if let cell, let place = places[cell.commitHash] { cell.slide(from: place) }
        }
    }
}
