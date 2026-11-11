import AppKit
import Core
import DesignKit
import KelpKit

/// A design's canvas in its tab: drawn again whenever a board or the design system changes on disk, checked each time
/// it's drawn, and the check handed to `kelp artifact check` when one waits for it.
extension MarkdownTab {
    /// The project a page in `.kelp/artifacts` belongs to: the folder that holds `.kelp`.
    nonisolated static func projectRoot(of path: String) -> String {
        path.range(of: "/\(Artifacts.folder)/").map { String(path[..<$0.lowerBound]) } ?? path
    }

    /// Follows the checks `kelp artifact check` asks for. Its boards and the design system are followed by the bar: a
    /// change to them moves the canvas's time in the artifacts' list (`boardsChanged`).
    func followCanvas() {
        let path = Paths.real(url.path) ?? url.path
        track(owner: self) { [app] in
            app.latest(ArtifactCheckEvent.self, path)
        } changed: { [weak self] event in
            guard let self, let event else { return }
            pendingCheck = event.request
            rerender()   // drawn again from the files as they are now, then answered
        }
    }

    /// A board or the design system changed on disk: drawn again.
    func boardsChanged() { rerender(after: .milliseconds(150)) }

    /// What Kelp's script found on the canvas just drawn: shown in the bar, and the answer to a waiting check.
    func canvasChecked(_ issues: [String]) {
        checkIssues = issues
        onCheck?(issues)
        guard let request = pendingCheck else { return }
        pendingCheck = nil
        Task { await app.quiet(UIBrowserReply(request: request, result: .array(issues.map(JSONValue.string)))) }
    }

    /// A message from Kelp's scripts on the canvas; false for one that isn't theirs.
    func canvasMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        switch kind {
        case "check": canvasChecked(body["issues"] as? [String] ?? [])
        case "marks": send(CanvasMark.message(marks(body), canvas: Artifacts.projectPath(url.path)), keep: [])
        case "marksDraft": keep(marks(body))
        case "pick":
            let row = (body["row"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            send(
                "Picked “\(row)” on \(Artifacts.projectPath(url.path)): build it out in full; take the other rows off "
                    + "canvas.json, keeping their files.", keep: nil)
        case "selected":
            chosen = (body["board"] as? String).flatMap { board in (body["id"] as? String).map { (board, $0) } }
        case "text":
            guard let board = body["board"] as? String, let old = body["old"] as? String,
                let text = body["text"] as? String
            else { return true }
            rewrite(board) { BoardEdit.setText($0, id: body["id"] as? String, old: old, new: text) }
        case "style":
            guard let board = body["board"] as? String, let id = body["id"] as? String,
                let property = body["property"] as? String
            else { return true }
            rewrite(board) { BoardEdit.setStyle($0, id: id, property: property, value: body["value"] as? String) }
        case "present":
            presentingBoards = false
            onPresentEnded?()
        case "themes":
            UserDefaults.standard.set(body["value"] as? String, forKey: CanvasPage.themesKey)
            rerender()
        case "zoom": canvasZoom = body["value"] as? Double
        case "source": modeSegment = 1
        case "fixCheck": sendCheck()
        case "fixCanvas":
            send(
                "\(Artifacts.projectPath(url.path)) doesn't read (\(body["why"] as? String ?? "")): fix it.", keep: nil)
        case "tweak":
            guard let board = body["board"] as? String, let name = body["name"] as? String,
                let value = body["value"] as? String
            else { return true }
            rewrite(board) { Tweak.set(name, to: value, in: $0) }
        default: return false
        }
        return true
    }

    var canvasLabels: CanvasEdit.Labels {
        let who = pageAuthor.map { app.catalog.name($0.agent) } ?? String(localized: "the Agent")
        return CanvasEdit.Labels(
            send: String(localized: "Send to \(who)"),
            pick: String(localized: "Pick"), tweaks: String(localized: "Tweaks"),
            note: String(localized: "What should change?"), remove: String(localized: "Remove"),
            marks: String(localized: "Marks"), check: String(localized: "Check"),
            askFix: String(localized: "Ask \(who) to Fix"),
            noMarks: String(localized: "Click an element on a board to mark it, then say what should change."),
            noIssues: String(localized: "No issues: nothing cut off, every text readable, every file there."),
            of: String(localized: "of"), escEnds: String(localized: "Esc to end"))
    }

    var canvasChromeLabels: CanvasChrome.Labels {
        CanvasChrome.Labels(
            light: String(localized: "Light"), dark: String(localized: "Dark"), both: String(localized: "Both"),
            fit: String(localized: "Fit"), zoomOut: String(localized: "Smaller"), zoomIn: String(localized: "Bigger"))
    }

    /// What a click on a board does: nothing (View), put a mark on it (Mark), or choose it to change by hand (Edit).
    enum CanvasMode: Int { case view, mark, edit }
    var canvasMode: CanvasMode { marking ? .mark : editing ? .edit : .view }

    /// The bar's View / Mark / Edit.
    func setCanvasMode(_ mode: CanvasMode) {
        marking = mode == .mark
        editing = mode == .edit
        if !editing { chosen = nil }
        runJS("kelpEdit(\(editing)); kelpMark(\(marking))")
    }

    /// Present in the bar: the boards one at a time, as large as the pane.
    func togglePresenting() {
        presentingBoards.toggle()
        if presentingBoards { focusPreview() }
        runJS("kelpPresent(\(presentingBoards))")
    }

    private func marks(_ body: [String: Any]) -> [CanvasMark] {
        (body["marks"] as? [[String: Any]] ?? []).compactMap { m in
            guard let board = m["board"] as? String, let target = m["target"] as? String else { return nil }
            return CanvasMark(
                board: board, target: target, text: m["text"] as? String ?? "", note: m["note"] as? String ?? "")
        }
    }

    private var notesPath: String { url.deletingLastPathComponent().appendingPathComponent(CanvasMark.file).path }

    /// The marks not sent yet, kept beside the canvas.
    private func keep(_ marks: [CanvasMark]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let text: String
        do { text = String(decoding: try encoder.encode(marks), as: UTF8.self) } catch { return }
        Task { await app.call(FilesWrite(path: notesPath, text: text, base: nil)) }
    }

    /// `line` to the chat that made the canvas (else the agent on screen); `keep`: the marks left after it.
    private func send(_ line: String, keep marks: [CanvasMark]?) {
        if let marks { keep(marks) }
        guard let author = pageAuthor else { return FileActions(app).sendToAgent(text: line) }
        Task { await app.call(SessionSend(id: author.id, text: line, enter: true)) }
    }

    /// A board's file changed by hand (a tweak, a style, a text), unless it changed since the page was drawn: then the
    /// edit can't be placed for sure, and the canvas draws again from the file.
    private func rewrite(_ board: String, _ change: @escaping (String) -> String?) {
        let path = url.deletingLastPathComponent().appendingPathComponent(board).path
        Task {
            guard let file = await app.call(FilesRead(path: path)) else { return }
            guard let text = change(file.text) else {
                Banner.show(String(localized: "Couldn't find that element in \(board) as it is now: drawn again."))
                return rerender()
            }
            await app.call(FilesWrite(path: path, text: text, base: file.stamp))
        }
    }

    var canvasEditLabels: CanvasEditMode.Labels {
        [
            "title": String(localized: "Properties"), "parent": String(localized: "Parent"),
            "asDrawn": String(localized: "As Drawn"),
            "noID": String(localized: "This element has no data-id: mark it and ask the agent to give it one."),
            "typeHint": String(localized: "Double-click it to change its text."),
            "choose": String(localized: "Click an element on a board to change its style, or double-click a text."),
            "text": String(localized: "Text"), "layout": String(localized: "Layout"), "fill": String(localized: "Fill"),
            "size": String(localized: "Size"), "weight": String(localized: "Weight"),
            "colour": String(localized: "Colour"),
            "padding": String(localized: "Padding"), "gap": String(localized: "Gap"),
            "background": String(localized: "Background"), "radius": String(localized: "Radius")
        ]
    }

    /// What's turned on again once the canvas is drawn again: marking or editing, and the element chosen.
    var canvasModeScripts: [String] {
        let zoom = canvasZoom.map { ["kelpZoom(\($0))"] } ?? []
        if marking { return zoom + ["kelpMark(true)"] }
        guard editing else { return zoom }
        let select = chosen.map { "kelpSelect(\(Self.jsString($0.board)), \(Self.jsString($0.id)))" }
        return zoom + ["kelpEdit(true)"] + (select.map { [$0] } ?? [])
    }

    /// An older version of the canvas made the files again: each of its boards, then the canvas.
    func restoreCanvas(_ snapshot: CanvasSnapshot) {
        let folder = url.deletingLastPathComponent()
        Task {
            for (board, text) in snapshot.boards.sorted(by: { $0.key < $1.key }) {
                guard
                    await app.call(FilesWrite(path: folder.appendingPathComponent(board).path, text: text, base: nil))
                        != nil
                else { return }
            }
            editor.apply(text: snapshot.canvas, selection: NSRange(location: 0, length: 0))
            _ = await saveFile?()
        }
    }

    /// The check's findings to the chat that made the canvas (else the agent on screen), to fix.
    func sendCheck() {
        guard let issues = checkIssues, !issues.isEmpty else { return }
        let line =
            "Fix on \(Artifacts.projectPath(url.path)) (kelp artifact check): "
            + issues.joined(separator: "; ")
        guard let author = pageAuthor else { return FileActions(app).sendToAgent(text: line) }
        Task { await app.call(SessionSend(id: author.id, text: line, enter: true)) }
    }
}

extension ArtifactCheckEvent: Pushed {
    package var key: String { path }
    package static var forgottenWith: WatchTopic? { nil }
}
