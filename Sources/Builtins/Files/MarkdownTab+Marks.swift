import AppKit
import Core
import KelpKit
import WebKit

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
        case "marks": sendMarks(drafts(body))
        case "marksDraft": change(.drafts(drafts(body)))
        case "markDone": if let id { change(.done(id: id)) }
        case "markAgain": if let id { change(.again(id: id)) }
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

    /// Sends the drafts: first as they are (so each has its number), then with a picture of each area and stroke, and
    /// then the message, to the chat that made the page (or the agent on screen).
    private func sendMarks(_ drafts: [ArtifactMark]) {
        Task {
            guard let numbered = await changed(.drafts(drafts)) else { return }
            let sending = numbered.marks.filter { $0.state == .draft }
            var pictures: [String: Data] = [:]
            for mark in sending where mark.kind == .area || mark.kind == .pen {
                do { pictures[String(mark.id)] = try await picture(of: mark.id) } catch {
                    continue   // the mark goes without its picture: the message still says where it is
                }
            }
            let to = pageAuthor?.id
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
            send(
                ArtifactMarks.message(
                    named, edits: numbered.edits, page: Artifacts.projectPath(url.path),
                    name: url.deletingLastPathComponent().lastPathComponent, version: version))
        }
    }

    /// A picture of mark `id` as it is on screen (an area, or a stroke with the board under it), as PNG. nil when the
    /// mark isn't on the page.
    private func picture(of id: Int) async throws -> Data? {
        let shown = try await web.evaluateJavaScript("window.kelpMarks?.reveal(\(id))", contentWorld: Self.world)
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
            "note": String(localized: "What should change?"),
            "whatsWrong": String(localized: "What isn’t right yet?"), "look": String(localized: "Look at this"),
            "you": String(localized: "You"), "agent": who, "marks": String(localized: "Marks"),
            "toCheck": String(localized: "To Check"), "fresh": String(localized: "New"),
            "yourEdits": String(localized: "Your Edits"), "withAgent": String(localized: "With \(who)"),
            "done": String(localized: "Done"), "again": String(localized: "Again"),
            "changedIn": String(localized: "Changed in version"), "goneIn": String(localized: "Gone in version"),
            "same": String(localized: "Not changed: its chat may say why")
        ]
    }
}
