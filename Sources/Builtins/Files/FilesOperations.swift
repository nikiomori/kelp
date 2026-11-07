import AppKit
import Core
import DesignKit
import KelpKit

/// File operations, done by the daemon (`files.*`: the same rules for every client, and a remote project's refused there
/// instead of acting on the folder that stands for it here), each undoable with ⌘Z.
extension FilesPanel {
    // ⌘Z is registered as the operation starts, not when the daemon answers: one registered while an undo runs is that
    // undo's redo, one registered later would be a new action (and clear the redo). What it undoes is the answer, awaited.

    /// Moves each pair (`unique`: a taken name becomes Finder's "name copy"); ⌘Z moves back what moved.
    @discardableResult
    func move(_ pairs: @escaping @MainActor () async -> [FileMove], unique: Bool = false, undo name: String) -> Task<
        [FileMove], Never
    > {
        let t = Task {
            let p = await pairs()
            guard !p.isEmpty, let r = await app.call(FilesMove(pairs: p, unique: unique)) else { return [FileMove]() }
            return done(r)
        }
        undoable(name, t) { $0.move({ await t.value.reversed().map(\.back) }, undo: name) }
        return t
    }

    /// Moves each to the Trash; ⌘Z moves them back from where they went.
    @discardableResult
    func trash(_ paths: @escaping @MainActor () async -> [String], undo name: String) -> Task<[FileMove], Never> {
        let t = Task {
            let p = await paths()
            fadeRows(Set(p))
            guard !p.isEmpty, let r = await app.call(FilesTrash(paths: p)) else {
                showFadedRows()
                return [FileMove]()
            }
            return done(r)
        }
        undoable(name, t) { $0.move({ await t.value.reversed().map(\.back) }, undo: name) }
        return t
    }

    /// Copies into `dir` (Finder's "name copy" when the name is taken); ⌘Z puts the copies in the Trash.
    func copy(_ paths: [String], into dir: String, undo name: String) {
        let t = Task {
            guard let r = await app.call(FilesCopy(paths: paths, into: dir)) else { return [String]() }
            if let e = r.error { Banner.show(e, style: .error) }
            reloadTree()
            return r.made
        }
        undoable(name, t) { $0.trash({ await t.value }, undo: name) }
    }

    /// A new file in `dir` ("untitled", "untitled 2"…); ⌘Z puts it in the Trash.
    func create(in dir: String, undo name: String) -> Task<String?, Never> {
        let t = Task { await app.call(FilesCreate(path: dir + "/untitled", unique: true)).map { [$0] } ?? [] }
        undoable(name, t) { $0.trash({ await t.value }, undo: name) }
        return Task { await t.value.first }
    }

    /// A row's key across a reload.
    func rowKey(_ row: Int) -> String? { (outline.item(atRow: row) as? FileNode)?.path }

    /// On their way to the Trash: the rows fade where they stand, and the reload closes the gap.
    private func fadeRows(_ paths: Set<String>) {
        guard !Motion.reduced else { return }
        outline.enumerateAvailableRowViews { v, row in
            guard let key = rowKey(row), paths.contains(URL(fileURLWithPath: root).appendingPathComponent(key).path)
            else { return }
            fadedRows.append(v)
            NSAnimationContext.runAnimationGroup {
                $0.duration = Motion.fast
                v.animator().alphaValue = 0
            }
        }
    }

    /// A row view is used again for another row: before a reload, or if the Trash refused.
    func showFadedRows() {
        fadedRows.forEach { $0.alphaValue = 1 }
        fadedRows = []
    }

    /// What moved; why the rest didn't, said.
    private func done(_ r: FilesMove.Result) -> [FileMove] {
        if let e = r.error { Banner.show(e, style: .error) }
        reloadTree()
        return r.done
    }

    /// ⌘Z for what `t` does, registered now: `inverse` runs on undo (and registers the redo). One that did nothing
    /// takes its entry back off, so ⌘Z doesn't skip a step.
    private func undoable<T: Collection>(
        _ name: String, _ t: Task<T, Never>, _ inverse: @escaping @MainActor (FilesPanel) -> Void
    ) {
        guard let um = undoManager else { return }
        let entry = UndoEntry()   // its own target, to be taken off alone
        // A step of its own, closed now: outside an event (after an await) the group opened by event would stay open
        // and take in the next action too, and one ⌘Z would undo both. Inside an undo, it's that undo's redo.
        let own = um.groupingLevel == 0
        if own {
            um.groupsByEvent = false
            um.beginUndoGrouping()
        }
        um.registerUndo(withTarget: entry) { [weak self] _ in
            _ = entry
            if let self { inverse(self) }
        }
        um.setActionName(name)
        if own {
            um.endUndoGrouping()
            um.groupsByEvent = true
        }
        Task { if await t.value.isEmpty { um.removeAllActions(withTarget: entry) } }
    }

    /// ⌘C: the file itself, for pasting here, in Finder, or into a terminal (its path).
    @objc func copy(_ sender: Any?) {
        guard let n = selectedNode else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([URL(fileURLWithPath: root).appendingPathComponent(n.path) as NSURL])
    }
    /// ⌘V: files copied here or in Finder, into the selected folder.
    @objc func paste(_ sender: Any?) {
        let urls =
            NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        copy(
            urls.map(\.path), into: URL(fileURLWithPath: root).appendingPathComponent(selectedDir).path,
            undo: String(localized: "Paste"))
    }
}

private final class UndoEntry {}

private extension FileMove {
    var back: FileMove { FileMove(from: to, to: from) }
}
