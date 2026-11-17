import AppKit
import Core
import DesignKit
import KelpKit

/// File operations, each undoable with ⌘Z. The daemon does them (`files.*`), so every client gets the same rules, and a
/// remote project's files change on its host, never in the folder that stands for it here.
extension FilesPanel {
    // The ⌘Z entry is registered when the operation starts, not when the daemon answers. An entry registered while an
    // undo runs becomes that undo's redo, but one registered later would be a new action and clear the redo. The entry
    // undoes what the daemon answers, once that answer arrives.

    /// Moves each pair of paths. With `unique`, a taken name becomes Finder's "name copy". ⌘Z moves back what moved.
    @discardableResult
    func move(_ pairs: @escaping @MainActor () async -> [FileMove], unique: Bool = false, undo name: String) -> Task<
        [FileMove], Never
    > {
        let task = Task {
            let moves = await pairs()
            guard !moves.isEmpty, let result = await app.call(FilesMove(pairs: moves, unique: unique)) else {
                return [FileMove]()
            }
            return done(result)
        }
        undoable(name, task) { $0.move({ await task.value.reversed().map(\.back) }, undo: name) }
        return task
    }

    /// Moves each path to the Trash. ⌘Z moves the files back from where they went.
    @discardableResult
    func trash(_ paths: @escaping @MainActor () async -> [String], undo name: String) -> Task<[FileMove], Never> {
        let task = Task {
            let targets = await paths()
            fadeRows(Set(targets))
            guard !targets.isEmpty, let result = await app.call(FilesTrash(paths: targets)) else {
                showFadedRows()
                return [FileMove]()
            }
            return done(result)
        }
        undoable(name, task) { $0.move({ await task.value.reversed().map(\.back) }, undo: name) }
        return task
    }

    /// Copies the paths into `dir`, as "name copy" (Finder's way) when a name is taken. ⌘Z puts the copies in the
    /// Trash.
    func copy(_ paths: [String], into dir: String, undo name: String) {
        let task = Task {
            guard let result = await app.call(FilesCopy(paths: paths, into: dir)) else { return [String]() }
            if let error = result.error { Banner.show(error, style: .error) }
            reloadTree()
            return result.made
        }
        undoable(name, task) { $0.trash({ await task.value }, undo: name) }
    }

    /// Creates a new file in `dir` ("untitled", "untitled 2"…). ⌘Z puts the file in the Trash.
    func create(in dir: String, undo name: String) -> Task<String?, Never> {
        let task = Task { await app.call(FilesCreate(path: dir + "/untitled", unique: true)).map { [$0] } ?? [] }
        undoable(name, task) { $0.trash({ await task.value }, undo: name) }
        return Task { await task.value.first }
    }

    /// The key that names a row across a reload: the path of the row's node.
    func rowKey(_ row: Int) -> String? { (outline.item(atRow: row) as? FileNode)?.path }

    /// Fades the rows of files on their way to the Trash, where they stand. The reload then closes the gap.
    private func fadeRows(_ paths: Set<String>) {
        guard !Motion.reduced else { return }
        outline.enumerateAvailableRowViews { rowView, row in
            guard let key = rowKey(row), paths.contains(URL(fileURLWithPath: root).appendingPathComponent(key).path)
            else { return }
            fadedRows.append(rowView)
            NSAnimationContext.runAnimationGroup {
                $0.duration = Motion.fast
                rowView.animator().alphaValue = 0
            }
        }
    }

    /// Makes the faded rows visible again, because a row view is reused for another row. This runs before a reload, or
    /// when the Trash refused.
    func showFadedRows() {
        fadedRows.forEach { $0.alphaValue = 1 }
        fadedRows = []
    }

    /// Returns what moved, and shows a banner that says why the rest didn't.
    private func done(_ result: FilesMove.Result) -> [FileMove] {
        if let error = result.error { Banner.show(error, style: .error) }
        reloadTree()
        return result.done
    }

    /// Registers ⌘Z for what `task` does, right away. `inverse` runs on undo and registers the redo. When the task did
    /// nothing, its entry comes back off, so ⌘Z doesn't skip a step.
    private func undoable<T: Collection>(
        _ name: String, _ task: Task<T, Never>, _ inverse: @escaping @MainActor (FilesPanel) -> Void
    ) {
        guard let um = undoManager else { return }
        let entry = UndoEntry()   // a target of its own, so this entry alone can be removed
        // Makes this a step of its own and closes it now. Outside an event (after an await), the group opened by the
        // event would stay open and take in the next action too, so one ⌘Z would undo both. Inside an undo, the step
        // is that undo's redo.
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
        Task { if await task.value.isEmpty { um.removeAllActions(withTarget: entry) } }
    }

    /// ⌘C copies the file itself, to paste here, in Finder, or into a terminal (where it pastes as its path).
    @objc func copy(_ sender: Any?) {
        guard let node = selectedNode else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([URL(fileURLWithPath: root).appendingPathComponent(node.path) as NSURL])
    }
    /// ⌘V copies the files copied here or in Finder into the selected folder.
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
