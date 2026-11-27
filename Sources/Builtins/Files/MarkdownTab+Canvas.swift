import AppKit
import Core
import DesignKit
import KelpKit

/// A design's canvas in its tab. The canvas is drawn again whenever a board or the design system changes on disk, and
/// it is checked each time it's drawn. When a `kelp artifact check` is waiting, the check's findings answer it.
extension MarkdownTab {
    /// The project a page in `.kelp/artifacts` belongs to: the folder that holds `.kelp`.
    nonisolated static func projectRoot(of path: String) -> String {
        path.range(of: "/\(Artifacts.folder)/").map { String(path[..<$0.lowerBound]) } ?? path
    }

    /// Follows the checks that `kelp artifact check` asks for. The bar follows the boards and the design system,
    /// because a change to them moves the canvas's time in the artifacts list (`boardsChanged`).
    func followCanvas() {
        let path = Paths.real(url.path) ?? url.path
        track(owner: self) { [app] in
            app.latest(ArtifactCheckEvent.self, path)
        } changed: { [weak self] event in
            guard let self, let event else { return }
            pendingCheck = event.request
            rerender()   // draws again from the files as they are now, then the check is answered
        }
    }

    /// Called when a board or the design system changed on disk, so the canvas is drawn again.
    func boardsChanged() { rerender(after: .milliseconds(150)) }

    /// Takes what Kelp's script found on the canvas just drawn. The bar shows it, and it answers a waiting check. What
    /// doesn't fit a phone's width (`@390:`) goes to the agent after its turn only while a board is shown that narrow
    /// (`narrow`): a desktop design isn't made to answer for a phone.
    func canvasChecked(_ issues: [String], narrow: Bool = false) {
        checkIssues = issues
        onCheck?(issues)
        let new = TurnCheck.of(self).checked(Self.told(issues, narrow: narrow))
        if !new.isEmpty, let author = pageAuthor {
            let text = TurnCheck.message(new, page: Artifacts.projectPath(url.path))
            Task { await app.call(SessionSend(id: author.id, text: text, enter: true)) }
        }
        guard let request = pendingCheck else { return }
        pendingCheck = nil
        Task { await app.quiet(UIBrowserReply(request: request, result: .array(issues.map(JSONValue.string)))) }
    }

    /// What of the check goes to the agent after its turn: the fit at a narrower width only while one is shown.
    nonisolated static func told(_ issues: [String], narrow: Bool) -> [String] {
        narrow ? issues : issues.filter { $0.firstMatch(of: #/ @\d+: /#) == nil }
    }

    /// Handles a message from Kelp's scripts on the canvas. Returns false when the message isn't one of theirs.
    func canvasMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        if arrangeMessage(kind, body) || propsMessage(kind, body) || slidesMessage(kind, body) { return true }
        if ["boardMenu", "keepVariant", "moreLike"].contains(kind) { return variantsMessage(kind, body) }
        if presetsMessage(kind, body) || captionsMessage(kind, body) || soundMessage(kind, body) { return true }
        if attributeMessage(kind, body) || tokenMessage(kind, body) { return true }
        switch kind {
        case "check": canvasChecked(body["issues"] as? [String] ?? [], narrow: body["narrow"] as? Bool ?? false)
        case "marks", "marksDraft", "markDone", "markAgain", "markRef", "markTarget", "marksTo", "stopAgent":
            marksMessage(kind, body)
        case "motion": motionMessage(body)
        case "undo": undoHandEdit(redo: body["redo"] as? Bool ?? false)
        case "review":
            let number = { (key: String) in (body[key] as? NSNumber)?.intValue ?? 0 }
            reviewBar.show(
                count: number("count"), at: number("at"),
                before: (body["before"] as? Bool ?? false, body["canBefore"] as? Bool ?? false),
                who: pageAuthor.map { app.catalog.name($0.agent) },
                said: (body["note"] as? String ?? "", body["reply"] as? String ?? ""), elsewhere: changedElsewhere,
                cost: roundCost)
        case "pick":
            let row = (body["row"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            send(
                "Picked “\(row)” on \(Artifacts.projectPath(url.path)): build it out in full; take the other rows off "
                    + "canvas.json, keeping their files.")
        case "selected":
            chosen = (body["board"] as? String).flatMap { board in (body["id"] as? String).map { (board, $0) } }
            if page == .motion { motionStudio.chose(chosen?.id ?? "") }
        case "text":
            guard let board = body["board"] as? String, let old = body["old"] as? String,
                let text = body["text"] as? String
            else { return true }
            let id = body["id"] as? String
            rewrite(board, edit: { _ in id.map { HandEdit(board: board, id: $0, what: "text", from: old, to: text) } })
            {
                BoardEdit.setText($0, id: id, old: old, new: text)
            }
        case "html":
            guard let board = body["board"] as? String, let id = body["id"] as? String,
                let html = body["html"] as? String, let text = body["text"] as? String
            else { return true }
            let old = body["old"] as? String
            rewrite(board, edit: { _ in HandEdit(board: board, id: id, what: "text", from: old, to: text) }) {
                BoardEdit.setInner($0, id: id, html: html)
            }
        case "style" where body["like"] is [String: Any], "styles" where body["like"] is [String: Any]:
            restyleAll(body)
        case "style":
            guard let board = body["board"] as? String, let id = body["id"] as? String,
                let property = body["property"] as? String
            else { return true }
            let value = body["value"] as? String
            let edit = { (source: String) in
                HandEdit(
                    board: board, id: id, what: property, from: BoardEdit.style(source, id: id, property: property),
                    to: value)
            }
            rewrite(board, edit: edit) { BoardEdit.setStyle($0, id: id, property: property, value: value) }
        case "styles":
            guard let board = body["board"] as? String, let id = body["id"] as? String,
                let props = body["props"] as? [String: Any], !props.isEmpty
            else { return true }
            let names = props.keys.sorted(), value = { (name: String) in props[name] as? String }
            let edit = { (source: String) in
                HandEdit(
                    board: board, id: id, what: names.joined(separator: ", "),
                    from: names.map { BoardEdit.style(source, id: id, property: $0) ?? "none" }.joined(separator: ", "),
                    to: names.map { value($0) ?? "none" }.joined(separator: ", "))
            }
            rewrite(board, edit: edit) { source in
                names.reduce(Optional(source)) { text, name in
                    text.flatMap { BoardEdit.setStyle($0, id: id, property: name, value: value(name)) }
                }
            }
        case "present":
            presentingBoards = false
            onPresentEnded?()
            Presenter.close(for: self)
        case "mode":
            let mode: CanvasMode = body["value"] as? String == "edit" ? .edit : .mark
            setCanvasMode(mode)
            onPageMode?(mode)
        case "changes": onChanges?((body["count"] as? NSNumber)?.intValue ?? 0)
        case "update":
            if refreshSources() { return true }
            send(
                "Update \(Artifacts.projectPath(url.path)): run its commands again and bring every figure up to date, "
                    + "its data-source time too.")
        case "zoom": zoomed(body["value"] as? Double)
        case "source": modeSegment = 1
        case "fixCheck": sendCheck()
        case "fixCanvas":
            send(
                "\(Artifacts.projectPath(url.path)) doesn’t read (\(body["why"] as? String ?? "")): fix it.")
        case "tweak":
            guard let board = body["board"] as? String, let name = body["name"] as? String,
                let value = body["value"] as? String
            else { return true }
            let edit = { (source: String) in
                HandEdit(
                    board: board, id: "tweak", what: name,
                    from: Tweak.all(in: source).first { $0.name == name }?.value, to: value)
            }
            rewrite(board, edit: edit) { Tweak.set(name, to: value, in: $0) }
        default: return false
        }
        return true
    }

    var canvasLabels: CanvasEdit.Labels {
        let who = pageAuthor.map { app.catalog.name($0.agent) } ?? String(localized: "the Agent")
        return CanvasEdit.Labels(
            pick: String(localized: "Pick"), tweaks: String(localized: "Tweaks"), check: String(localized: "Check"),
            askFix: String(localized: "Ask \(who) to Fix"),
            noMarks: String(
                localized: "Click an element on a board to mark it, or drag over an area, then say what should change."
            ),
            noIssues: String(localized: "No issues: nothing cut off, every text readable, every file there."),
            of: String(localized: "of"), escEnds: String(localized: "⎋ to end"),
            element: String(localized: "Element"),
            area: String(localized: "Area"), pen: String(localized: "Pen"), arrow: String(localized: "Arrow"),
            label: String(localized: "Label"), whole: String(localized: "The Whole Video"),
            wholePage: String(localized: "The Whole Page"))
    }

    var canvasChromeLabels: CanvasChrome.Labels {
        CanvasChrome.Labels(
            fit: String(localized: "Fit"), zoomOut: String(localized: "Smaller"), zoomIn: String(localized: "Bigger"))
    }

    /// What a click on a board does: nothing (View), put a mark on it (Mark), or choose it to change by hand (Edit).
    /// On a doc or slides, Edit shows the source beside the page.
    enum CanvasMode: Int { case view, mark, edit }
    var canvasMode: CanvasMode {
        if marking { return .mark }
        if page == .canvas || page == .motion { return editing ? .edit : .view }
        guard isViewLoaded else { return startInPreview ? .view : .edit }
        return modeSegment == 2 ? .view : .edit
    }

    /// Sets the mode chosen with View / Mark / Edit in the bar.
    /// ⋯ › Try On on a canvas: its boards' text as written, 40% longer or right to left (not in Edit, which writes
    /// what they show), and one theme or both, each under its section's title.
    func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: String(localized: "Text")))
        for (view, title) in [
            ("as", String(localized: "As Written")), ("longer", String(localized: "Longer Text (+40%)")),
            ("rtl", String(localized: "Right to Left"))
        ] {
            let item = menu.add(title) { [weak self] in
                self?.canvasLanguage = view
                self?.runJS("window.kelpLanguage?.(\(Self.js(view)))")
            }
            item.state = canvasLanguage == view ? .on : .off
            item.isEnabled = view == "as" || !editing
        }
        if isDashboard { return menu }   // a dashboard follows the window's look
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Appearance")))
        for (themes, title) in [
            (CanvasPage.Themes.light, String(localized: "Light")), (.dark, String(localized: "Dark")),
            (.both, String(localized: "Both"))
        ] {
            menu.add(title) { [weak self] in
                CanvasPage.chosenThemes = themes
                self?.rerender()
            }.state = CanvasPage.chosenThemes == themes ? .on : .off
        }
        return menu
    }

    func setCanvasMode(_ mode: CanvasMode) {
        if mode == .edit { canvasLanguage = "as" }   // Edit shows the boards as they are
        if mode != .view { (split.arrangedSubviews.last as? VersionsPanel)?.removeFromSuperview() }   // one column
        marking = mode == .mark
        if marking { followAuthor() }
        guard page != .canvas && page != .motion else {
            editing = mode == .edit
            if !editing { chosen = nil }
            if page == .motion { motionStudio.marking = marking }
            return runJS("kelpEdit(\(editing)); kelpMark(\(marking))")
        }
        // On a doc or slides, the source shows beside the page, or alone while the pane is too narrow for both.
        let segment = mode == .edit ? (narrowPane ? 0 : 1) : 2
        if modeSegment != segment { modeSegment = segment }
        if mode == .edit { editor.focus() }
        runJS("window.kelpMark?.(\(marking))")
    }

    /// The words shown for a doc's marks and in its column (`PageMarks`).
    var pageMarkLabels: [String: String] {
        [
            "mark": String(localized: "Mark It"), "contents": String(localized: "Contents"),
            "noMarks": String(localized: "Select text on the page to mark it, then say what should change."),
            "noContents": String(localized: "No headings on this page."),
            "check": canvasLabels.check, "askFix": canvasLabels.askFix, "noIssues": canvasLabels.noIssues
        ]
    }

    /// Update on a dashboard: asks the agent to run the numbers again.
    func askUpdate() { _ = canvasMessage("update", [:]) }

    /// Starts or stops presenting, for Present in the bar. Presenting shows the boards one at a time, as large as
    /// the pane.
    func togglePresenting() {
        presentingBoards.toggle()
        if !presentingBoards { Presenter.close(for: self) }
        if presentingBoards { focusPreview() }
        runJS("kelpPresent(\(presentingBoards))")
    }

    /// Sends `line` to the chat that made the page, or else to the agent on screen.
    func send(_ line: String) {
        guard let author = pageAuthor else { return FileActions(app).sendToAgent(text: line) }
        Task { await app.call(SessionSend(id: author.id, text: line, enter: true)) }
    }

    /// Writes a change made by hand (a tweak, a style, a text) into a board's file. When the file changed since the
    /// page was drawn, the edit can't be placed for sure, so nothing is written and the canvas draws again from the
    /// file. A change written is kept for the agent (`edit`, made from the file before the change).
    func rewrite(
        _ board: String, by step: UUID? = nil, edit: @escaping (String) -> HandEdit?,
        _ change: @escaping (String) -> String?
    ) {
        let path = url.deletingLastPathComponent().appendingPathComponent(board).path
        if path == url.path {   // a motion page's stage is the tab's own file
            if let made = edit(editor.text) { rewritePage(made, change) }
            return
        }
        // One after another: a data-id given at an element's first change is written before that change reads it.
        let before = lastRewrite
        lastRewrite = Task {
            await before?.value
            // Written against the file as read; when the agent wrote it in between, once more on what it wrote.
            for _ in 0..<2 {
                guard let file = await app.call(FilesRead(path: path)) else { return }
                guard let text = change(file.text) else {
                    Banner.show(String(localized: "That element isn’t in \(board) any more: here it is as it is now."))
                    return rerender()
                }
                guard let written = await app.call(FilesWrite(path: path, text: text, base: file.stamp)) else { return }
                if written.conflict != nil { continue }
                if written.missing != true, let made = edit(file.text) {
                    didHandEdit(made, path: path, before: file.text, after: text, by: step)
                }
                return
            }
            Banner.show(
                String(localized: "\(board) changed while you edited it, so that edit isn’t written.")
            )
            rerender()
        }
    }

    var canvasEditLabels: CanvasEditMode.Labels {
        [
            "title": String(localized: "Properties"),
            "choose": String(localized: "Click an element on a board to change its style, or double-click a text."),
            "text": String(localized: "Text"), "layout": String(localized: "Layout"),
            "position": String(localized: "Position"), "fill": String(localized: "Fill"),
            "time": String(localized: "Time"), "size": String(localized: "Size"),
            "weight": String(localized: "Weight"), "colour": String(localized: "Color"),
            "padding": String(localized: "Padding"), "gap": String(localized: "Gap"),
            "background": String(localized: "Background"), "radius": String(localized: "Radius"),
            "opacity": String(localized: "Opacity"), "offset": String(localized: "Offset"),
            "frame": String(localized: "Width · Height"), "startLength": String(localized: "Start · Length"),
            "none": String(localized: "None"), "auto": String(localized: "auto"),
            "regular": String(localized: "Regular"), "medium": String(localized: "Medium"),
            "semibold": String(localized: "Semibold"), "bold": String(localized: "Bold"),
            "reset": String(localized: "Back to the Page’s Own"), "seconds": String(localized: "s"),
            "font": String(localized: "Font"), "align": String(localized: "Alignment"),
            "align_left": String(localized: "Align Left"), "align_center": String(localized: "Align Center"),
            "align_right": String(localized: "Align Right")
        ]
    }

    /// The scripts that turn things back on after the canvas is drawn again: the zoom, marking or editing, and the
    /// chosen element.
    var canvasModeScripts: [String] {
        let zoom =
            (canvasZoom.map { ["kelpZoom(\($0))"] } ?? []) + ["window.kelpLanguage?.(\(Self.js(canvasLanguage)))"]
        if marking { return zoom + ["kelpMark(true)", busyScript] }
        guard editing else { return zoom }
        let select = chosen.map { "kelpSelect(\(Self.js($0.board)), \(Self.js($0.id)))" }
        return zoom + ["kelpEdit(true)"] + (select.map { [$0] } ?? [])
    }

    /// Restores an older version of the canvas by writing its files again: each of its boards, then the canvas.
    func restoreCanvas(_ snapshot: CanvasSnapshot) async -> Bool {
        let folder = url.deletingLastPathComponent()
        for (board, text) in snapshot.boards.sorted(by: { $0.key < $1.key }) {
            guard
                await app.call(FilesWrite(path: folder.appendingPathComponent(board).path, text: text, base: nil))
                    != nil
            else { return false }
        }
        return await save(snapshot.canvas).value
    }

    /// Sends the check's findings to the chat that made the canvas (or else to the agent on screen), to fix.
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
