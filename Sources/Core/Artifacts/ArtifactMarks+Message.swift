import Foundation

extension ArtifactMarks {
    /// The message that sends `marks` (drafts about to go) to the agent, with the hand edits waiting. `page` is the
    /// page's path in the project (`.kelp/artifacts/home/canvas.json`), `name` its folder's name, and `version` the
    /// version they are sent with.
    public static func message(
        _ marks: [ArtifactMark], edits: [HandEdit], page: String, name: String, version: Int?
    ) -> String {
        let folder = (page as NSString).deletingLastPathComponent
        var lines = [
            "Marks on \(page)\(version.map { " (version \($0))" } ?? ""). Change only what each mark points at; "
                + "if you can't or won't, say why with `kelp artifact reply \(name) <#> \"…\"`."
        ]
        for m in marks {
            var what = [m.board]
            switch m.kind {
            case .element where m.like != nil: what += ["\(m.like ?? "") (every element like it, on every board)"]
            case .element: what += [m.target, m.text.isEmpty ? "" : "«\(m.text)»"]
            case .quote: what += ["«\(m.text)»"]
            case .area where m.area == nil && m.path == nil: what.append("the whole page")
            case .area, .pen:
                let near = m.target.isEmpty ? "" : " near \(m.target)"
                let box = m.area.map { a in " " + a.map { String(Int($0.rounded())) }.joined(separator: ",") } ?? ""
                what.append((m.kind == .area ? "area" : "pen") + (m.kind == .area ? box : near))
                if !m.text.isEmpty { what.append("labelled «\(m.text)»") }
            }
            if let time = m.time { what.append(String(format: "at %.2f s", time)) }
            if let state = m.inState { what.append("in state «\(state)»") }
            if let asked = m.asked { what.append("(you asked: «\(asked)»)") }
            if let reference = m.reference { what.append("(example: \(folder)/\(reference))") }
            if let picture = m.picture { what.append("(picture: \(folder)/\(picture))") }
            let head = "#\(m.id)" + (m.rounds.isEmpty ? "" : " again")
            let note = m.note.isEmpty ? "look at this" : m.note
            lines.append(([head] + what.filter { !$0.isEmpty }).joined(separator: " ") + ": " + note)
            if let last = m.rounds.last {
                let said = last.reply.map { "; you said «\($0)»" } ?? ""
                lines.append("  (before: «\(last.note)»\(said))")
            }
        }
        if !edits.isEmpty {
            lines.append("Edited by the user since\(version.map { " version \($0)" } ?? " then"), keep these:")
            for e in edits {
                let change =
                    e.what == "text"
                    ? "text «\(e.from ?? "")» → «\(e.to ?? "")»" : "\(e.what) \(e.from ?? "none") → \(e.to ?? "none")"
                lines.append("  \(e.board) [data-id=\(e.id)] \(change)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
