// How a file tab saves: autosave, writes only over a known version, following the disk when it changes under the tab,
// and asking on close.
import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

extension FileTab {
    /// Asks about unsaved changes in a sheet, like any Mac document: Save, Don't Save, or keep the tab. With autosave
    /// on, it asks only when writing isn't safe, because an agent changed the file meanwhile or the file was moved or
    /// deleted.
    func close() async -> Bool {
        autosaving.cancel()
        _ = await saving?.value   // a save on its way finishes first, so the check sees what it wrote
        guard let editor, isEdited else { return true }
        // Keep the version this check is made against, because the write may replace only that version on disk,
        // whatever is read meanwhile.
        let action = FileSync.save(buffer: editor.text, saved: lastSaved, disk: disk), checked = known?.stamp
        if autosave, action == .write, await writeAndClose(over: checked) { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Do you want to save the changes you made to “\(title)”?")
        alert.informativeText =
            switch action {
            case .conflict:
                String(localized: "An agent changed it on disk meanwhile. Save replaces that version with yours.")
            case .missing: String(localized: "It was moved or deleted. Save writes it at its old place again.")
            default: String(localized: "Your changes will be lost if you don’t save them.")
            }
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don’t Save"))
        switch await runSheet(alert) {
        case .alertFirstButtonReturn:
            await tidy()
            return await writeAndClose(answering: action, over: checked)
        case .alertThirdButtonReturn:
            discard()
            return true
        default: return false
        }
    }
}

extension FileTab {
    // MARK: saving

    func edited(_ text: String) {
        edits += 1
        backup.keep(text)
        if autosave { autosaving.after(0.6) { [weak self] in Task { await self?.autosaveNow() } } }
        editedStateMayHaveChanged()
        markdown?.textChanged()
        conflicts?.edited(editor?.lastEdit)
        guard lspOpenedOn != nil else { return }   // no language server has the file (none does on another machine)
        lspTask?.cancel()
        lspUnsent = text
        lspTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.sendUnsent()
        }
    }

    /// The file as the daemon last gave or pushed it: missing, or its text as last read or written here (nil when the
    /// file isn't UTF-8). New versions keep it current (`diskChanged`), so the check before a save reads nothing. The
    /// daemon then writes only over that version, so a change the tab hasn't heard of yet is still never written over.
    var disk: FileSync.Disk { gone ? .missing : .present(known?.text) }

    /// Saves the file for ⌘S, Save All, the Save button on a sheet, and quitting. The text is tidied first (`tidy`) and
    /// then written. Returns false when the file couldn't be written, or when the user must be asked first because an
    /// agent changed the file meanwhile or the file is gone.
    @discardableResult
    func save() async -> Bool {
        guard editor != nil else { return true }
        await tidy()
        return await serially { [self] in
            guard let editor else { return true }
            switch FileSync.save(buffer: editor.text, saved: lastSaved, disk: disk) {
            case .write:
                if await write() { return true }
                return gone ? await askToWriteBack() : false
            case .conflict:
                apply(disk)
                return false   // don't write over an agent's edit; ask instead
            case .missing: return await askToWriteBack()
            default: return true
            }
        }
    }

    /// Tidies the text before a save the user asks for: trailing spaces, the final newline, and Format on Save.
    /// Autosave skips this, because it would move the line being typed.
    func tidy() async {
        rules?.cleanUpForSave()
        // A remote file isn't formatted, because its formatter would run on this Mac, not on the host (`format`).
        if app.settings[SettingKeys.formatOnSave, language: editor?.languageId], language?.format != nil, !remote {
            await format()
        }
    }

    /// Asks before writing a file that was moved or deleted (git mv, a rename), because writing would bring the old
    /// file back beside the new one.
    private func askToWriteBack() async -> Bool {
        guard
            await confirm(
                String(localized: "“\(title)” was moved or deleted"),
                detail: String(localized: "Save writes it at its old place again."),
                action: String(localized: "Save Here"))
        else { return false }
        return await write(overAnything: true)
    }

    /// Autosaves the file, only when writing is safe. A conflict asks the user (if the tab is on screen), and a missing
    /// file waits for ⌘S.
    private func autosaveNow() async {
        _ = await serially { [self] in
            guard let editor else { return true }
            switch FileSync.save(buffer: editor.text, saved: lastSaved, disk: disk) {
            case .write: return await write()
            case .conflict:
                apply(disk)
                return false
            default: return true
            }
        }
    }

    /// Runs saves one at a time, so each is checked against what the save before it wrote, not what is still on its
    /// way. The task holds the tab, so a tab closed right after Save (or whose workspace closed) still gets written.
    private func serially(_ save: @escaping @MainActor () async -> Bool) async -> Bool {
        let previous = saving
        let next = Task {
            _ = await previous?.value
            return await save()
        }
        saving = next
        return await next.value
    }

    /// Writes the buffer to the file through the daemon (atomically, and through a symlink to the file it points at),
    /// only over the version last read or written here. With `overAnything` it writes over whatever is there (Save
    /// Here). When the file changed meanwhile the user is asked, unless the file was only touched (its text is still
    /// what this tab last saved), and then it is written over once. Call it only through `serially`. `checked` is the
    /// version a caller checked before a wait of its own (closing); without it, the version known now is used.
    private func write(overAnything: Bool = false, touched: Bool = false, checked: FileStamp? = nil) async -> Bool {
        guard let editor else { return true }
        // Make a native Swift string off the main thread (5 MB took 400 ms on it). The buffer is compared against this
        // text on every keystroke, and that is fast only with a Swift string on this side (`FileSync.same`). Take the
        // version the save was checked against before the wait, because an agent's version read meanwhile isn't it.
        let buffer = editor.text, at = edits, base = overAnything ? nil : checked ?? known?.stamp
        let text = await Task.detached { String(decoding: Data(buffer.utf8), as: UTF8.self) }.value
        writing = true
        let res = await app.tryCall(FilesWrite(path: path, text: text, base: base))
        writing = false
        defer {
            if readAgain {
                readAgain = false
                diskChanged()
            }
        }   // read again for a version pushed meanwhile: the tab's own, or an agent's right after
        if let error = res.error {
            Banner.show(String(localized: "Couldn’t save \(title): \(error)"), style: .error)
            return false
        }
        guard let written = res.value else { return false }
        if let stamp = written.stamp {
            gone = false
            known = (stamp, text)
            saved(text, at: at)
            changeBars?.refresh()
            return true
        }
        if written.missing == true {
            gone = true
            return false
        }
        guard let conflict = written.conflict else { return false }
        known = (conflict.stamp, conflict.text)
        if !touched, let now = conflict.text, FileSync.same(now, lastSaved) { return await write(touched: true) }
        apply(.present(conflict.text))   // an agent's edit, so the user is asked
        return false
    }

    /// Saves and then lets the tab close. The tab waits until the file is written, and stays open (with its edits) when
    /// the write fails. `answering` is what the sheet said Save does, so a Save that puts a deleted file back or
    /// replaces an agent's version really does that. `over` is the version that was checked, so an agent's version read
    /// after that check isn't written over.
    func writeAndClose(answering action: FileSync.Action = .write, over checked: FileStamp? = nil) async -> Bool {
        await serially { [self] in await write(overAnything: action != .write, checked: checked) }
    }

    var pendingSave: Task<Void, Never>? { saving.map { s in Task { _ = await s.value } } }

    /// Records that the file now holds `text` (written or taken from disk), which the buffer held after `at` edits.
    /// When no edit came since, the tab is no longer edited; otherwise the buffer is compared.
    private func saved(_ text: String, at: Int) {
        lastSaved = text
        if at == edits { setEdited(false) } else { editedStateMayHaveChanged() }
    }

    /// Works out after a keystroke whether the buffer differs from the saved text. Most keystrokes change the buffer's
    /// length, which answers at once. One that doesn't (a letter typed over, an undo back to the saved text) needs a
    /// compare, done off the main thread for a big file (33 ms for 5 MB). The tab counts as edited during that compare,
    /// so a quit right then still asks.
    private func editedStateMayHaveChanged() {
        comparing?.cancel()
        guard let text = editor?.text else { return setEdited(false) }
        let length = text.utf16.count
        guard length == lastSaved.utf16.count else { return setEdited(true) }
        guard length > 100_000 else { return setEdited(!FileSync.same(text, lastSaved)) }
        setEdited(true)
        let saved = lastSaved
        comparing = Task {
            let same = await Task.detached { FileSync.same(text, saved) }.value
            if !Task.isCancelled { setEdited(!same) }
        }
    }

    private func setEdited(_ now: Bool) {
        if now != isEdited { isEdited = now }
        if !now { backup.drop() }
    }

    /// Handles a new version the daemon pushed (`WatchTopic.file`). The file is read again only for a version this tab
    /// didn't read or write itself (a log that a dev server appends to changes every quarter second). One read runs at
    /// a time, and versions that come during a read or while a save writes the file cause one more read. A tab that
    /// isn't on screen and has nothing unsaved reads the file once it shows, because otherwise an agent rewriting files
    /// would make every open tab read, compare and take each version.

    func diskChanged() {
        if editor != nil, !isEdited, !whenShown.onScreen, app.latest(FileEvent.self, path)?.stamp != nil {
            return whenShown.run { [weak self] in self?.diskChanged() }
        }
        changeBars?.refresh()
        showProblems()
        guard editor != nil, let event = app.latest(FileEvent.self, path) else { return }
        if reading || writing {
            readAgain = true
            return
        }
        guard let now = event.stamp else {
            apply(.missing)
            return
        }
        if let known, known.stamp == now { return }   // our own write
        reading = true
        let filePath = path
        Task { [weak self, app] in
            let read: Result<FilesRead.Result, Error>
            do { read = .success(try await app.get(FilesRead(path: filePath))) } catch { read = .failure(error) }
            guard let self else { return }
            reading = false
            switch read {
            case .success(let file):
                known = (file.stamp, file.text)
                apply(.present(file.text))
            case .failure(let error) where Unopenable(error) == .binary:
                known = (now, nil)
                apply(.present(nil))   // the user is asked, as for a file that is no longer text
            case .failure: break   // the file is too big now (a log), a pipe, or gone; the tab keeps its text
            }
            if readAgain {
                readAgain = false
                diskChanged()
            }
        }
    }

    private func apply(_ onDisk: FileSync.Disk) {
        guard let editor else { return }
        let wasGone = gone
        gone = onDisk == .missing
        switch FileSync.diskChanged(buffer: editor.text, saved: lastSaved, disk: onDisk) {
        case .follow(let text):   // no local edits: follow the disk
            editor.setText(text)
            saved(text, at: edits)
            markdown?.textChanged()
            conflicts?.refresh()
        case .conflict(let text): askKeepMine(disk: text)
        case .missing where !wasGone && isEdited:
            Banner.show(goneNote(title))
        default: break
        }
    }

    /// What the tab says of a file that went from under it, in its banner and its tooltip. Save is named by its key as
    /// it stands, or by its name when it has no key.
    func goneNote(_ name: String) -> String {
        let save = app.extensions.keyText("editor.save") ?? String(localized: "Save")
        return String(localized: "\(name) was moved or deleted. \(save) asks before writing it there again.")
    }

    private func askKeepMine(disk: String) {
        guard let editor, let window = view.window, window.attachedSheet == nil else { return }   // asked again on the next change or ⌘S
        let alert = NSAlert()
        alert.messageText = String(localized: "\(title) changed on disk")
        alert.informativeText = String(localized: "An agent edited this file while you had unsaved changes.")
        // When the file is no longer text (another encoding, or binary), there is no disk version to show, and an empty
        // one would throw the edits away. Keep Mine writes the edits, and Cancel leaves the tab and the file as they
        // are.
        let notText: Bool = if case .present(nil) = self.disk { true } else { false }
        if notText {
            alert.informativeText = String(
                localized:
                    "The file on disk is no longer text (another encoding, or binary). Keep Mine writes your version over it."
            )
        }
        // Keep Mine writes over the version shown now, not over one an agent saves while the sheet is up.
        let checked = known?.stamp
        alert.addButton(withTitle: String(localized: "Keep Mine"))
        alert.addButton(withTitle: notText ? String(localized: "Cancel") : String(localized: "Use Disk Version"))
        // The handler holds the tab until the user answers, so closing the tab meanwhile can't lose the choice (or the
        // edits).
        alert.beginSheetModal(for: window) { response in   // AppKit calls this on the main thread
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn {
                    self.lastSaved = disk
                    Task { _ = await self.serially { await self.write(checked: checked) } }
                } else if !notText {
                    editor.setText(disk)
                    self.saved(disk, at: self.edits)
                    self.markdown?.textChanged()
                }
            }
        }
    }
}
