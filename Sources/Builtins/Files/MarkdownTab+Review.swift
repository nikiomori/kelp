// A review page's answers in the Markdown preview: a point's answer written back, a quote asked about.
import AppKit
import Core
import EditorKit
import KelpKit
import WebKit

extension MarkdownTab {
    // MARK: a review's answers

    /// The chat that made this page (a review's answers go back to it, and questions about it), while it's there.
    var pageAuthor: Session? {
        Artifacts.record(in: url.deletingLastPathComponent())?.session.flatMap(app.session).flatMap {
            $0.status == .exited ? nil : $0
        }
    }

    /// A pick, a note, the recommended picks or Change Answers go into the file (the agent reads its answers there);
    /// Send types the line saying them into the chat that wrote it, or, once that has ended, into the agent on screen
    /// for the user to send, and the file says when.
    func answer(_ kind: String, point: String, value: String) {
        let text: String? =
            switch kind {
            case "pick": Review.pick(editor.text, point: point, option: value)
            case "note": Review.note(editor.text, point: point, note: value)
            case "recommended": Review.pickRecommended(editor.text)
            case "unsend": Review.unsent(editor.text)
            default: nil
            }
        if let text { editor.apply(text: text, selection: NSRange(location: 0, length: 0)) }
        Task {
            guard await saveFile?() != false else { return }
            guard kind == "send" else { return }
            let line = Review(editor.text).answer(file: Artifacts.projectPath(url.path))
            if let author = pageAuthor {
                guard await app.call(SessionSend(id: author.id, text: line, enter: true)) != nil else { return }
            } else {
                FileActions(app).sendToAgent(text: line)
            }
            let now = Date().formatted(date: .omitted, time: .shortened)
            editor.apply(text: Review.markSent(editor.text, at: now), selection: NSRange(location: 0, length: 0))
            _ = await saveFile?()
        }
    }

    /// `value` as a JavaScript literal (JSON is one): a string, the marks, the labels of a page's script.
    nonisolated static func js(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return String(decoding: try encoder.encode(value), as: UTF8.self) } catch { return "null" }
    }
}
