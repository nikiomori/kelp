import AppKit
import Core

/// More about each mark for the agent, found when the marks go (`ArtifactMarks.message`'s `details`): an element's
/// opening tag in its board's file and how it looks on the page (size, weight, colour, ground, padding, gap); a quote's
/// line in the Markdown and the heading it sits under. About twenty words a mark, and the agent needn't read the file
/// first to find it.
extension MarkdownTab {
    func markDetails(_ marks: [ArtifactMark]) async -> [Int: String] {
        var details: [Int: String] = [:]
        let folder = url.deletingLastPathComponent()
        for mark in marks {
            if mark.kind == .quote, let place = Self.place(of: mark.text, in: editor.text) {
                details[mark.id] =
                    Artifacts.projectPath(url.path) + ":\(place.line)"
                    + (place.heading.map { " under «\($0)»" } ?? "")
                continue
            }
            guard mark.kind == .element, mark.like == nil, let id = mark.elementID else { continue }
            let path = folder.appendingPathComponent(mark.board).path
            let source = path == url.path ? editor.text : await app.quiet(FilesRead(path: path))?.text ?? ""
            let tag = BoardEdit.element(source, id: id).flatMap { $0.firstMatch(of: /<[^>]*>/) }.map {
                String($0.output)
            }
            let look = await self.look(board: mark.board, id: id)
            let parts = [tag.map { String($0.prefix(120)) + ($0.count > 120 ? "…" : "") }, look].compactMap { $0 }
            if !parts.isEmpty { details[mark.id] = parts.joined(separator: "; ") }
        }
        return details
    }

    /// How element `id` of `board` looks on the page as drawn, in a few words.
    private func look(board: String, id: String) async -> String? {
        let script = """
            const f = [...document.querySelectorAll('iframe[data-board]')]
              .find(f => f.dataset.board === board && f.dataset.theme !== 'dark');
            const e = f?.contentDocument?.querySelector('[data-id="' + CSS.escape(id) + '"]');
            if (!e) return null;
            const s = getComputedStyle(e), out = [s.fontSize + ' ' + s.fontWeight, 'colour ' + s.color];
            if (!/rgba\\(0, 0, 0, 0\\)|transparent/.test(s.backgroundColor)) out.push('ground ' + s.backgroundColor);
            if (s.padding !== '0px') out.push('padding ' + s.padding);
            if (s.gap && s.gap !== 'normal') out.push('gap ' + s.gap);
            return out.join(', ');
            """
        return await withCheckedContinuation { go in
            web.callAsyncJavaScript(script, arguments: ["board": board, "id": id], in: nil, in: Self.world) { read in
                // A page not drawn yet: the tag alone says enough.
                if case .success(let words as String) = read {
                    go.resume(returning: words)
                } else {
                    go.resume(returning: nil)
                }
            }
        }
    }

    /// Where quote `quote` is in `markdown`: its line (from 1), and the heading above it.
    nonisolated static func place(of quote: String, in markdown: String) -> (line: Int, heading: String?)? {
        let words = quote.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        let lines = markdown.components(separatedBy: "\n")
        let flat = { (s: String) in s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        // The words may run on over a line break: a line holds the first, and it with the next few holds them all.
        let first = String(words.prefix { !$0.isWhitespace })
        guard
            let at = lines.indices.first(where: { index in
                flat(lines[index]).contains(first)
                    && flat(lines[index..<min(index + 4, lines.count)].joined(separator: " ")).contains(words)
            })
        else { return nil }
        let heading = lines[...at].last { $0.hasPrefix("#") }.map {
            $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        }
        return (at + 1, heading)
    }
}
