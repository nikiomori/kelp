// A review page's answers in the Markdown preview: a point's answer written back, a quote asked about.
import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import Markdown
import WebKit

extension MarkdownTab {
    // MARK: a review's answers

    /// The chat that made this page (a review's answers go back to it, and questions about it), while it's there.
    var pageAuthor: Session? {
        Artifacts.record(in: url.deletingLastPathComponent())?.session.flatMap(app.session).flatMap {
            $0.status == .exited ? nil : $0
        }
    }

    /// A pick or a note goes into the file (the agent reads its answers there); Send types the line saying them into
    /// the chat that wrote it, or, once that has ended, into the agent on screen for the user to send.
    func answer(_ kind: String, point: String, value: String) {
        switch kind {
        case "pick":
            editor.apply(
                text: Review.pick(editor.text, point: point, option: value), selection: NSRange(location: 0, length: 0))
        case "note":
            editor.apply(
                text: Review.note(editor.text, point: point, note: value), selection: NSRange(location: 0, length: 0))
        default: break
        }
        Task {
            guard await saveFile?() != false else { return }
            guard kind == "send" else { return }
            let line = Review(editor.text).answer(file: Artifacts.projectPath(url.path))
            guard let author = pageAuthor else { return FileActions(app).sendToAgent(text: line) }
            guard await app.call(SessionSend(id: author.id, text: line, enter: true)) != nil else { return }
            let sent = String(localized: "Sent to \(author.title)")
            runJS("kelpReviewSent(\(Self.js(sent)))")
        }
    }

    /// Text selected on the page, quoted into the chat that made it (else the agent on screen), not sent: the user asks.
    func ask(about quote: String) {
        let quoted = quote.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(
            separator: " ")
        guard !quoted.isEmpty else { return }
        let shown = quoted.count > 400 ? String(quoted.prefix(399)) + "…" : quoted
        let line = "About “\(shown)” in \(Artifacts.projectPath(url.path)):"
        guard let author = pageAuthor else { return FileActions(app).sendToAgent(text: line) }
        Task { await app.call(SessionSend(id: author.id, text: line + " ", enter: false)) }
        app.workbench.focus(session: author.id)
    }

    /// `value` as a JavaScript literal (JSON is one): a string, the marks, the labels of a page's script.
    nonisolated static func js(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return String(decoding: try encoder.encode(value), as: UTF8.self) } catch { return "null" }
    }
}
