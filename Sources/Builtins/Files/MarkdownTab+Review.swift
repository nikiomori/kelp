// The answers on a review page in the Markdown preview: each point's answer is written back into the file, and Send
// hands the answers to the agent.
import AppKit
import Core
import EditorKit
import KelpKit
import WebKit

extension MarkdownTab {
    // MARK: a review's answers

    /// The chat that made this page, while that chat is still running. A review's answers, and questions about the
    /// page, go back to it.
    var pageAuthor: Session? {
        Artifacts.record(in: url.deletingLastPathComponent())?.session.flatMap(app.session).flatMap {
            $0.status == .exited ? nil : $0
        }
    }

    /// Writes a pick, a note, the recommended picks or Change Answers into the file, because the agent reads its
    /// answers there. Send types a line with the answers into the chat that wrote the review. When that chat has
    /// ended, the line goes into the agent on screen for the user to send. Then the file records when it was sent.
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
            _ = await save(Review.markSent(editor.text, at: now)).value
        }
    }

    /// Returns `value` as a JavaScript literal, by encoding it as JSON. It's used for a string, the marks, and the
    /// labels of a page's script.
    nonisolated static func js(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return String(decoding: try encoder.encode(value), as: UTF8.self) } catch { return "null" }
    }
}
