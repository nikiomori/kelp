import Foundation

extension ArtifactMarks {
    /// Returns the marks in the `notes.json` in `folder`, as `read(_:)` does; none when it is too big to be one.
    package static func read(in folder: URL) -> ArtifactMarks {
        read(Artifacts.small(folder.appendingPathComponent(file).path))
    }

    /// The message that sends `marks` (drafts about to go) to the agent, with the hand edits waiting. `page` is the
    /// page's path in the project (`.kelp/artifacts/home/canvas.json`), `name` its folder's name, and `version` the
    /// version they are sent with. `details` says more about some marks, by number: an element's opening tag and its
    /// look, a quote's line and heading, so the agent finds them without reading the file first.
    public static func message(
        _ marks: [ArtifactMark], edits: [HandEdit], page: String, name: String, version: Int?,
        details: [Int: String] = [:], kind: String? = nil
    ) -> String {
        let folder = (page as NSString).deletingLastPathComponent
        var lines = [
            "Marks on \(page)\(version.map { " (version \($0))" } ?? ""). Change only what each mark points at; "
                + "leave the other boards, kit.css and the design system's tokens as they are, and ask first "
                + "(`kelp artifact reply`) when a mark needs them changed. If you can't or won't, say why with "
                + "`kelp artifact reply \(name) <#> \"…\"`."
                // A chat that didn't make the page, or lost its rules to compaction, finds them again.
                + (kind.map { " Rules: `kelp artifact guide \($0)`." } ?? "")
        ]
        for mark in marks {
            var what = [mark.board]
            switch mark.kind {
            case .element where mark.like != nil: what += ["\(mark.like ?? "") (every element like it, on every board)"]
            case .element: what += [mark.target, mark.text.isEmpty ? "" : "«\(mark.text)»"]
            case .quote: what += ["«\(mark.text)»"]
            case .area where mark.area == nil && mark.path == nil: what.append("the whole page")
            case .area, .pen:
                let near = mark.target.isEmpty ? "" : " near \(mark.target)"
                let box = mark.area.map { a in " " + a.map { String(Int($0.rounded())) }.joined(separator: ",") } ?? ""
                what.append((mark.kind == .area ? "area" : "pen") + (mark.kind == .area ? box : near))
                if !mark.text.isEmpty { what.append("labelled «\(mark.text)»") }
            }
            if let time = mark.time { what.append(String(format: "at %.2f s", time)) }
            if let state = mark.inState { what.append("in state «\(state)»") }
            if let width = mark.width { what.append("at \(width)px wide") }
            if let language = mark.language {
                what.append(language == "rtl" ? "laid out right to left" : "with its text 40% longer")
            }
            if let asked = mark.asked { what.append("(you asked: «\(asked)»)") }
            if let reference = mark.reference { what.append("(example: \(folder)/\(reference))") }
            if let picture = mark.picture { what.append("(picture: \(folder)/\(picture))") }
            let head = "#\(mark.id)" + (mark.rounds.isEmpty ? "" : " again")
            // A note that starts with "?" asks rather than asks for a change: the answer is a reply, the page stays.
            let question = mark.note.hasPrefix("?")
            let asked = question ? String(mark.note.dropFirst()).trimmingCharacters(in: .whitespaces) : mark.note
            let note =
                (asked.isEmpty ? "look at this" : asked)
                + (question
                    ? " (a question: answer it with `kelp artifact reply \(name) \(mark.id) \"…\"`, change nothing for it)"
                    : "")
            lines.append(([head] + what.filter { !$0.isEmpty }).joined(separator: " ") + ": " + note)
            if let more = details[mark.id] { lines.append("  (\(more))") }
            if let last = mark.rounds.last {
                let said = last.reply.map { "; you said «\($0)»" } ?? ""
                lines.append("  (before: «\(last.note)»\(said))")
            }
        }
        if !edits.isEmpty {
            lines.append("Edited by the user since\(version.map { " version \($0)" } ?? " then"), keep these:")
            for edit in edits {
                let change =
                    edit.what == "text"
                    ? "text «\(edit.from ?? "")» → «\(edit.to ?? "")»"
                    : "\(edit.what) \(edit.from ?? "none") → \(edit.to ?? "none")"
                lines.append("  \(edit.board) [data-id=\(edit.id)] \(change)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
