// Saving a file tab: autosave, writes over a known version, the disk changing under it, asking on close.
import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

extension FileTab {
    /// Asks about unsaved changes in a sheet, like any Mac document: Save, Don't Save, or keep the tab. With autosave
    /// it only asks when writing isn't safe: an agent changed the file meanwhile, or it was moved or deleted.
    func close() async -> Bool {
        autosaving.cancel()
        _ = await saving?.value   // a save on its way: what's asked is checked against what it wrote
        guard let editor, isEdited else { return true }
        let action = FileSync.save(buffer: editor.text, saved: lastSaved, disk: disk)
        if autosave, action == .write, await writeAndClose() { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Do you want to save the changes you made to “\(title)”?")
        alert.informativeText =
            switch action {
            case .conflict:
                String(localized: "An agent changed it on disk meanwhile. Save replaces that version with yours.")
            case .missing: String(localized: "It was moved or deleted. Save writes it at its old place again.")
            default: String(localized: "Your changes will be lost if you don't save them.")
            }
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        switch await runSheet(alert) {
        case .alertFirstButtonReturn: return await writeAndClose(answering: action)
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
        guard lspOpenedOn != nil else { return }   // no language server for it (or for a file on another machine)
        lspTask?.cancel()
        lspUnsent = text
        lspTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.sendUnsent()
        }
    }

    /// The file as the daemon last gave or pushed it: gone, or its text as last read or written here (nil: not UTF-8).
    /// Kept current by its version (`diskChanged`), so a save's check reads nothing; the daemon then writes only over
    /// that version, so a change it hasn't heard of yet is still never written over.
    var disk: FileSync.Disk { gone ? .missing : .present(known?.text) }

    /// ⌘S. False when it couldn't be written, or the user is asked first (an agent changed the file meanwhile, or it's gone).
    @discardableResult
    func save() async -> Bool {
        guard editor != nil else { return true }
        return await serially { [self] in
            guard let editor else { return true }
            switch FileSync.save(buffer: editor.text, saved: lastSaved, disk: disk) {
            case .write:
                if await write() { return true }
                return gone ? await askToWriteBack() : false
            case .conflict:
                apply(disk)
                return false   // don't clobber an agent's edit: ask
            case .missing: return await askToWriteBack()
            default: return true
            }
        }
    }

    /// Moved or deleted (git mv, a rename): writing would bring the old file back beside the new one, so it asks.
    private func askToWriteBack() async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(title)” was moved or deleted")
        alert.informativeText = String(localized: "Save writes it at its old place again.")
        alert.addButton(withTitle: String(localized: "Save Here"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard await runSheet(alert) == .alertFirstButtonReturn else { return false }
        return await write(overAnything: true)
    }

    /// Autosave writes only when that's safe; a conflict asks (if the tab is on screen), a missing file waits for ⌘S.
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

    /// Saves go one at a time, each checked against what the one before wrote, not what's on its way. The task holds
    /// the tab: one closed (or its workspace) right after Save still gets written.
    private func serially(_ save: @escaping @MainActor () async -> Bool) async -> Bool {
        let previous = saving
        let next = Task {
            _ = await previous?.value
            return await save()
        }
        saving = next
        return await next.value
    }

    /// The buffer to the file, by the daemon (atomically, through a symlink to the file it points at), only over the version
    /// last read or written here; `overAnything`: whatever is there (Save Here). Changed meanwhile: asked about, unless
    /// only touched (its text still what this tab last saved), which is written over once. Only through `serially`.
    private func write(overAnything: Bool = false, touched: Bool = false) async -> Bool {
        guard let editor else { return true }
        // A Swift string, made off the main thread (5 MB took 400 ms on it): the buffer is compared against it on every
        // keystroke, fast only with a Swift string on this side (`FileSync.same`).
        let buffer = editor.text, at = edits
        let text = await Task.detached { String(decoding: Data(buffer.utf8), as: UTF8.self) }.value
        writing = true
        let res = await app.tryCall(FilesWrite(path: path, text: text, base: overAnything ? nil : known?.stamp))
        writing = false
        defer {
            if readAgain {
                readAgain = false
                diskChanged()
            }
        }   // its own version pushed, or an agent's right after
        if let error = res.error {
            Banner.show(String(localized: "Couldn't save \(title): \(error)"), style: .error)
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
        apply(.present(conflict.text))   // an agent's edit: asked about
        return false
    }

    /// Closing with a save: the tab waits until the file has it, and stays (with its edits) when that failed.
    /// `answering`: what the sheet said it does, so a Save that puts a deleted file back or replaces an agent's version does.
    func writeAndClose(answering action: FileSync.Action = .write) async -> Bool {
        await serially { [self] in await write(overAnything: action != .write) }
    }

    var pendingSave: Task<Void, Never>? { saving.map { s in Task { _ = await s.value } } }

    /// The file is `text` now (written or taken from disk), and the buffer was it `at` that many keystrokes: still is, or
    /// it's compared.
    private func saved(_ text: String, at: Int) {
        lastSaved = text
        if at == edits { setEdited(false) } else { editedStateMayHaveChanged() }
    }

    /// After a keystroke. Most change the buffer's length, which tells at once; one that doesn't (a letter typed over, an
    /// undo back to the saved text) is compared, off the main thread for a big file (33 ms for 5 MB). Edited meanwhile:
    /// a quit right then still asks.
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

    /// A new version pushed (`WatchTopic.file`): read again only one this tab didn't read or write itself (a log a dev
    /// server appends to changes every quarter second). One read at a time; versions meanwhile make one more, as do
    /// versions while a save writes the file.

    func diskChanged() {
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
                apply(.present(nil))   // asked about as such
            case .failure: break   // grown past the limit (a log), a pipe now, or gone (its next version says so): kept as shown
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
        case .conflict(let text): askKeepMine(disk: text)
        case .missing where !wasGone && isEdited:
            Banner.show(String(localized: "\(title) was moved or deleted. ⌘S asks before writing it there again."))
        default: break
        }
    }

    private func askKeepMine(disk: String) {
        guard let editor, let window = view.window, window.attachedSheet == nil else { return }   // asked again on the next change or ⌘S
        let alert = NSAlert()
        alert.messageText = String(localized: "\(title) changed on disk")
        alert.informativeText = String(localized: "An agent edited this file while you had unsaved changes.")
        // No longer text (another encoding, binary): there's no disk version to show, and an empty one would throw the
        // edits away. Keep Mine writes them; Cancel leaves the tab and the file as they are.
        let notText: Bool = if case .present(nil) = self.disk { true } else { false }
        if notText {
            alert.informativeText = String(
                localized:
                    "The file on disk is no longer text (another encoding, or binary). Keep Mine writes your version over it."
            )
        }
        alert.addButton(withTitle: String(localized: "Keep Mine"))
        alert.addButton(withTitle: notText ? String(localized: "Cancel") : String(localized: "Use Disk Version"))
        // Holds the tab until answered: closing it meanwhile mustn't throw away the user's choice (or their edits).
        alert.beginSheetModal(for: window) { response in   // AppKit: on main
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn {
                    self.lastSaved = disk
                    Task { _ = await self.serially { await self.write() } }
                } else if !notText {
                    editor.setText(disk)
                    self.saved(disk, at: self.edits)
                    self.markdown?.textChanged()
                }
            }
        }
    }
}
