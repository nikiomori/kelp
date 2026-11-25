import AppKit
import Core
import DesignKit
import KelpKit
import UniformTypeIdentifiers

/// What Edit does to a whole element on a board or a motion page's stage: take it out, copy it, bring it to the front
/// or send it to the back, give an image another picture. ⌫ and ⌘D on the page, or its menu (a right click).
extension MarkdownTab {
    /// Handles `remove`, `duplicate` and `menu` from the page. Returns false for another kind.
    func arrangeMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        if kind == "restyle" {
            restyle(body)
            return true
        }
        if kind == "removeMany" {
            removeMany(body)
            return true
        }
        if kind == "giveID" {
            giveID(body)
            return true
        }
        guard ["remove", "duplicate", "menu", "copyElement", "pasteElement"].contains(kind) else { return false }
        guard let board = body["board"] as? String, let id = body["id"] as? String else { return true }
        switch kind {
        case "remove": removeElement(board, id)
        case "duplicate": duplicateElement(board, id)
        case "copyElement": copyElement(board, id)
        case "pasteElement": pasteElement(board, after: id)
        default:
            elementMenu(
                board, id, image: body["image"] as? Bool ?? false, media: body["media"] as? Bool ?? false,
                chart: body["chart"] as? String ?? "")
        }
        return true
    }

    /// Sets the properties of several elements as one edit: the layers restacked on a motion page's timeline.
    private func restyle(_ body: [String: Any]) {
        guard let board = body["board"] as? String, let changes = body["changes"] as? [[String: Any]] else { return }
        let list = changes.compactMap { c -> (String, [String: String])? in
            guard let id = c["id"] as? String, let props = c["props"] as? [String: String] else { return nil }
            return (id, props)
        }
        guard !list.isEmpty else { return }
        let edit = { (_: String) in
            HandEdit(
                board: board, id: list[0].0, what: body["what"] as? String ?? "stacking", from: nil,
                to: list.map(\.0).joined(separator: " > "))
        }
        rewrite(board, edit: edit) { source in
            list.reduce(Optional(source)) { text, change in
                change.1.keys.sorted().reduce(text) { text, name in
                    text.flatMap { BoardEdit.setStyle($0, id: change.0, property: name, value: change.1[name]) }
                }
            }
        }
    }

    /// Writes a data-id into the element found as the `index`th `<tag>` of the board, and chooses it, so Edit can
    /// change it.
    private func giveID(_ body: [String: Any]) {
        guard let board = body["board"] as? String, let tag = body["tag"] as? String,
            let index = (body["index"] as? NSNumber)?.intValue, index >= 0
        else { return }
        let named = body["id"] as? String   // the one the page gave it already
        let edit = { [weak self] (source: String) -> HandEdit? in
            guard let given = BoardEdit.giveID(source, tag: tag, index: index, named: named) else { return nil }
            self?.chosen = (board, given.id)
            return HandEdit(board: board, id: given.id, what: "data-id", from: nil, to: given.id)
        }
        rewrite(board, edit: edit) { BoardEdit.giveID($0, tag: tag, index: index, named: named)?.text }
    }

    /// Locks element `id` in place (`data-locked`): the stage doesn't choose or move it, the timeline still does.
    func lockElement(_ id: String, _ lock: Bool) {
        let edit = { (_: String) in
            HandEdit(
                board: MotionPage.board, id: id, what: "locked", from: lock ? nil : "true", to: lock ? "true" : nil)
        }
        rewrite(MotionPage.board, edit: edit) {
            BoardEdit.setAttribute($0, id: id, name: "data-locked", value: lock ? "true" : nil)
        }
    }

    /// Hides element `id` from the page and the video (`data-hidden`), or shows it again.
    func hideElement(_ id: String, _ hide: Bool) {
        let edit = { (_: String) in
            HandEdit(
                board: MotionPage.board, id: id, what: "hidden", from: hide ? nil : "true", to: hide ? "true" : nil)
        }
        rewrite(MotionPage.board, edit: edit) {
            BoardEdit.setAttribute($0, id: id, name: "data-hidden", value: hide ? "true" : nil)
        }
    }

    /// Takes element `id` out of `board`.
    /// Takes several chosen elements out of a board at once: one hand edit.
    private func removeMany(_ body: [String: Any]) {
        guard let board = body["board"] as? String, let ids = body["ids"] as? [String], let first = ids.first else {
            return
        }
        chosen = nil
        let edit = { (_: String) in
            HandEdit(board: board, id: first, what: "removed", from: ids.joined(separator: ", "), to: nil)
        }
        rewrite(board, edit: edit) { source in
            ids.reduce(Optional(source)) { text, id in text.flatMap { BoardEdit.remove($0, id: id) } }
        }
    }

    func removeElement(_ board: String, _ id: String) {
        chosen = nil
        let edit = { (source: String) in
            HandEdit(board: board, id: id, what: "removed", from: BoardEdit.element(source, id: id), to: nil)
        }
        rewrite(board, edit: edit) { BoardEdit.remove($0, id: id) }
    }

    /// Puts a copy of element `id` right after it and chooses the copy. A scene of a motion page is copied after
    /// itself in time too, and the scenes after it move later by its length.
    func duplicateElement(_ board: String, _ id: String) {
        let scene = page == .motion ? motionStudio.scenes.first { $0.id == id } : nil
        let later = scene.map { s in motionStudio.scenes.filter { $0.id != id && $0.start >= s.end - 0.001 } } ?? []
        let change = { (source: String) -> String? in
            guard let copy = BoardEdit.duplicate(source, id: id) else { return nil }
            guard let scene else { return copy.text }
            let moved = later.reduce(Optional(copy.text)) { text, other in
                text.flatMap {
                    BoardEdit.setAttribute(
                        $0, id: other.id, name: "data-start", value: Self.seconds(other.start + scene.length))
                }
            }
            return moved.flatMap {
                BoardEdit.setAttribute($0, id: copy.id, name: "data-start", value: Self.seconds(scene.end))
            }
        }
        // The copy is chosen, so the page drawn again shows it chosen.
        let edit = { [weak self] (source: String) -> HandEdit? in
            guard let copy = BoardEdit.duplicate(source, id: id) else { return nil }
            self?.chosen = (board, copy.id)
            return HandEdit(board: board, id: id, what: "copied as \(copy.id)", from: nil, to: copy.id)
        }
        rewrite(board, edit: edit, change)
    }

    /// The menu of element `id`, at the pointer.
    private func elementMenu(_ board: String, _ id: String, image: Bool, media: Bool, chart: String) {
        let menu = NSMenu()
        menu.add(String(localized: "Duplicate"), key: "d") { [weak self] in self?.duplicateElement(board, id) }
        menu.add(String(localized: "Bring to Front")) { [weak self] in self?.runJS("window.kelpArrange?.(true)") }
        menu.add(String(localized: "Send to Back")) { [weak self] in self?.runJS("window.kelpArrange?.(false)") }
        if image {
            menu.add(String(localized: "Replace Picture…")) { [weak self] in self?.replaceImage(board, id) }
        }
        if media { menu.add(String(localized: "Crop")) { [weak self] in self?.runJS("window.kelpCrop?.()") } }
        if !chart.isEmpty {
            menu.add(String(localized: "Numbers…")) { [weak self] in
                self?.runJS("window.kelpChartNumbers?.(\(Self.js(board)), \(Self.js(chart)))")
            }
        }
        menu.add(String(localized: "Insert"), submenu: insertMenu(board, after: id))
        if page == .motion { menu.add(String(localized: "Insert Block"), submenu: blocksMenu()) }
        if page == .canvas {
            menu.add(String(localized: "Take from a Table…")) { [weak self] in self?.chooseTable(board, id) }
            menu.add(String(localized: "Variations of This Board")) { [weak self] in
                guard let self else { return }
                send(Self.variations(of: board, page: Artifacts.projectPath(url.path), like: nil))
            }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Delete"), key: "\u{8}") { [weak self] in self?.removeElement(board, id) }
            .keyEquivalentModifierMask = []   // ⌫, as the page takes it
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Asks for a picture, copies it beside the page, and points image `id` at it.
    func replaceImage(_ board: String, _ id: String) {
        Task { await askForImage(board, id) }
    }

    /// The panel for Replace Picture…, once the element is found to be an image.
    private func askForImage(_ board: String, _ id: String) async {
        let path = url.deletingLastPathComponent().appendingPathComponent(board).path
        let source = path == url.path ? editor.text : await app.quiet(FilesRead(path: path))?.text
        guard let window = view.window, BoardEdit.element(source ?? "", id: id)?.lowercased().hasPrefix("<img") == true
        else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .OK, let picked = panel.url else { return }
            Task { @MainActor in await self?.setImage(board, id, to: picked) }
        }
    }

    /// Copies `file` into the page's folder (as "name copy.png" when the name is taken) and sets image `id`'s `src`.
    func setImage(_ board: String, _ id: String, to file: URL) async {
        let folder = url.deletingLastPathComponent().path
        guard let copied = await app.call(FilesCopy(paths: [file.path], into: folder)) else { return }
        guard let path = copied.made.first else {
            return Banner.show(copied.error ?? String(localized: "Couldn’t copy the picture."), style: .error)
        }
        let name = (path as NSString).lastPathComponent
        let edit = { (source: String) in
            HandEdit(board: board, id: id, what: "src", from: Self.attribute(source, id: id, "src"), to: name)
        }
        rewrite(board, edit: edit) { BoardEdit.setAttribute($0, id: id, name: "src", value: name) }
    }

    /// The value of attribute `name` in element `id`'s opening tag.
    private static func attribute(_ source: String, id: String, _ name: String) -> String? {
        guard let tag = BoardEdit.element(source, id: id)?.prefix(while: { $0 != ">" }),
            let start = tag.range(of: " \(name)=\""), let end = tag[start.upperBound...].firstIndex(of: "\"")
        else { return nil }
        return String(tag[start.upperBound..<end])
    }
}
