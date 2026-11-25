import AppKit
import Core
import DesignKit
import KelpKit
import WebKit
import WorkbenchKit

/// The marks on an agent's page, as the tab handles them (`MarkColumn` draws them): the daemon writes every change to
/// notes.json, and the page gets the marks back as written. A send keeps the pictures of areas and strokes, and goes to
/// the chat as numbered lines (`ArtifactMarks.message`). Hand edits wait for the next send; a pause in them keeps a
/// version of the page as the user's.
extension MarkdownTab {
    /// How long hand edits rest before they are kept as the user's version.
    static let handEditPause: Double = 4

    func marksMessage(_ kind: String, _ body: [String: Any]) {
        let id = (body["id"] as? NSNumber)?.intValue
        switch kind {
        case "marks":
            sendMarks(drafts(body), queue: body["queue"] as? Bool ?? false, seen: (body["seen"] as? NSNumber)?.intValue)
        case "marksDraft":
            let list = drafts(body), seen = (body["seen"] as? NSNumber)?.intValue
            Task { change(.drafts(await stampIDs(list), seen: seen)) }
        case "markDone": if let id { change(.done(id: id)) }
        case "markRef":
            // An example picture, kept as PNG whatever it came as.
            guard let id, let data = (body["data"] as? String).flatMap({ Data(base64Encoded: $0) }),
                let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            else { break }
            change(.reference(id: id), pictures: [String(id): png])
        case "markAgain": if let id { change(.again(id: id)) }
        case "markTarget":
            // Point Again on a mark that isn't a draft (drafts go with the rest, `marksDraft`).
            guard let id, let mark = drafts(["marks": [body["mark"] ?? [:]]]).first else { break }
            Task { if let mark = await stampIDs([mark]).first { change(.retarget(id: id, to: mark)) } }
        default: break
        }
    }

    private func drafts(_ body: [String: Any]) -> [ArtifactMark] {
        guard let list = body["marks"] as? [Any], JSONSerialization.isValidJSONObject(list) else { return [] }
        do {
            return try JSONDecoder().decode(
                [ArtifactMark].self, from: try JSONSerialization.data(withJSONObject: list))
        } catch {
            return []   // a page that sends what isn't a mark changes nothing
        }
    }

    /// Changes the marks, and gives the page the marks as written.
    private func change(_ change: ArtifactMarks.Change, pictures: [String: Data]? = nil) {
        Task { await changed(change, pictures: pictures) }
    }

    @discardableResult
    private func changed(_ change: ArtifactMarks.Change, pictures: [String: Data]? = nil) async -> ArtifactMarks? {
        guard let marks = await app.call(ArtifactMarksChange(path: url.path, change: change, pictures: pictures))
        else { return nil }
        runJS("window.kelpMarks?.set(\(Self.js(marks)))")
        return marks
    }

    /// Sends the drafts, in order: first all drafts as they
    /// are (so each has its number), then with a picture of each area and stroke, and then the message, to the chat
    /// that made the page (or the agent on screen). With `queue` while that agent works, they wait for its turn to end.
    private func sendMarks(_ drafts: [ArtifactMark], queue: Bool, seen: Int?) {
        Task {
            // Who gets them is settled first: with no agent to take them, they stay drafts.
            guard let agent = await markTaker() else { return }
            guard let numbered = await changed(.drafts(await stampIDs(drafts), seen: seen)) else { return }
            let all = numbered.marks.filter { $0.state == .draft }
            let sending = all
            if queue, agent.status == .working {
                markQueue += sending.map(\.id).filter { !markQueue.contains($0) }
                return followAuthor()
            }
            await deliver(sending, edits: numbered.edits, to: agent)
        }
    }

    /// Sends `sending` with `edits` to `agent`: their pictures, their state, then the message.
    private func deliver(_ sending: [ArtifactMark], edits: [HandEdit], to agent: Session) async {
        var pictures: [String: Data] = [:]
        for mark in sending where mark.kind == .area || mark.kind == .pen || mark.time != nil {
            do { pictures[String(mark.id)] = try await picture(of: mark) } catch {
                continue   // the mark goes without its picture: the message still says where it is
            }
        }
        let to = agent.id
        guard
            let sent = await changed(
                .send(ids: sending.map(\.id), to: to, before: nil), pictures: pictures.isEmpty ? nil : pictures)
        else { return }
        let named = sending.map { m in
            var m = m
            m.picture = sent.marks.first { $0.id == m.id }?.picture
            return m
        }
        let version = sent.marks.first { sending.map(\.id).contains($0.id) }?.rounds.last?.before
        let text = ArtifactMarks.message(
            named, edits: edits, page: Artifacts.projectPath(url.path),
            name: url.deletingLastPathComponent().lastPathComponent, version: version)
        await app.call(SessionSend(id: agent.id, text: text, enter: true))
        app.workbench.showBeside(session: agent.id, of: TabURI.file(url.path))   // the page stays where it is
    }

    /// The page's agent at work, for the column's band (`kelpMarks.busy`): its name and how many marks wait for it.
    var busyScript: String {
        let who = pageAuthor.flatMap { $0.status == .working ? app.catalog.name($0.agent) : nil } ?? ""
        return "window.kelpMarks?.busy(\(Self.js(who)), \(markQueue.count))"
    }

    /// Follows the page's agent once marks are shown: the band says when it works, and the queue (`markQueue`, the
    /// numbers of the marks waiting for its turn to end) goes when it stops.
    func followAuthor() {
        runJS(busyScript)
        guard !followingAuthor else { return }
        followingAuthor = true
        track(owner: self, now: false) { [weak self] in
            self?.pageAuthor?.status
        } changed: { [weak self] status in
            guard let self else { return }
            runJS(busyScript)
            TurnCheck.of(self).agent(working: status == .working, issues: checkIssues)
            guard status != .working, let agent = pageAuthor, !markQueue.isEmpty else { return }
            let ids = markQueue
            markQueue = []
            runJS(busyScript)
            Task { await self.sendQueued(ids, to: agent) }
        }
    }

    /// The queued drafts that are still drafts, in the drafts' order, sent to `agent`.
    private func sendQueued(_ ids: [Int], to agent: Session) async {
        let notes = url.deletingLastPathComponent().appendingPathComponent(ArtifactMarks.file).path
        guard let file = await app.quiet(FilesRead(path: notes)) else { return }
        let marks = ArtifactMarks.read(Data(file.text.utf8))
        let sending = marks.marks.filter { $0.state == .draft && ids.contains($0.id) }
        guard !sending.isEmpty else { return }
        await deliver(sending, edits: marks.edits, to: agent)
    }

    /// The chat the marks go to: the one that made the page while it runs, else the agent on screen (asking which when
    /// there are several). nil, with a banner, when there is none.
    private func markTaker() async -> Session? {
        if let author = pageAuthor, author.status != .exited { return author }
        let actions = FileActions(app)
        guard !actions.agents().isEmpty else {
            actions.sendToAgent(text: "")   // with no agent, it only says how to start one
            return nil
        }
        return await actions.pickAgent()
    }

    /// A picture of `mark` as it is on screen (an area, or a stroke with the board under it), or of a motion page's
    /// whole frame at the mark's second, as PNG. nil when the mark isn't on the page.
    private func picture(of mark: ArtifactMark) async throws -> Data? {
        let shown: Any?
        if let time = mark.time {
            shown = try await web.callAsyncJavaScript(
                "await window.kelpMotion.frameAt(at); return window.kelpMotion.stage().slice(0, 4)",
                arguments: ["at": time], contentWorld: Self.world)
            runJS("window.kelpMotion?.done()")
        } else {
            shown = try await web.evaluateJavaScript("window.kelpMarks?.reveal(\(mark.id))", contentWorld: Self.world)
        }
        guard let box = shown as? [Double], box.count == 4 else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3]).intersection(web.bounds)
        let image = try await web.takeSnapshot(configuration: config)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Called when the daemon changed the marks (a turn ended, an agent answered). With `redraw`, the page is drawn
    /// again, because marks to check bring the boards as they were sent; otherwise the page takes the marks in place.
    func marksChanged(redraw: Bool) {
        if redraw { return rerender() }
        let notes = url.deletingLastPathComponent().appendingPathComponent(ArtifactMarks.file).path
        Task {
            guard let file = await app.quiet(FilesRead(path: notes)) else { return }
            runJS("window.kelpMarks?.set(\(Self.js(ArtifactMarks.read(Data(file.text.utf8)))))")
        }
    }

    /// Keeps a hand edit for the next send, and once the edits rest, the page as the user's version, named by the
    /// elements changed.
    func keepHandEdit(_ edit: HandEdit) {
        change(.edit(edit))
        handEdited.insert(edit.id == "tweak" ? edit.what : edit.id)
        handEditRest.after(Self.handEditPause) { [weak self] in
            guard let self else { return }
            let label = handEdited.sorted().joined(separator: ", "), path = url.path
            handEdited = []
            Task { await app.quiet(ArtifactKeepVersion(path: path, label: label)) }
        }
    }

    /// The words of the marks' column (`MarkColumn`).
    var markColumnLabels: [String: String] {
        let who = pageAuthor.map { app.catalog.name($0.agent) } ?? String(localized: "the Agent")
        return [
            "send": String(localized: "Send to \(who)"), "remove": String(localized: "Remove"),
            "note": String(localized: "What should change? A picture dropped here is an example."),
            "whatsWrong": String(localized: "What isn’t right yet?"), "look": String(localized: "Look at this"),
            "you": String(localized: "You"), "agent": who, "marks": String(localized: "Marks"),
            "toCheck": String(localized: "To Check"), "fresh": String(localized: "New"),
            "yourEdits": String(localized: "Your Edits"), "withAgent": String(localized: "With \(who)"),
            "done": String(localized: "Done"), "again": String(localized: "Again"),
            "changedIn": String(localized: "Changed in version"), "goneIn": String(localized: "Gone in version"),
            "same": String(localized: "Not changed: its chat may say why"),
            "composeHint": String(localized: "↩ add  ·  ⌘↩ send  ·  ⎋ remove"),
            "sendCount": String(localized: "Send %d"),
            "queue": String(localized: "Queue"), "sendNow": String(localized: "Send Now"),
            "working": String(localized: "%@ is working"), "queued": String(localized: "%d queued"),
            "asks": String(localized: "%@ asks"), "answer": String(localized: "Your answer"),
            "next": String(localized: "Next you might ask"), "allLike": String(localized: "All like this"),
            "waiting": String(localized: "Waiting"), "all": String(localized: "All"),
            "noneDone": String(localized: "No mark is done yet.")
        ]
    }
}
