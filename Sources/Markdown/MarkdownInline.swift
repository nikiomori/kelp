import Foundation

/// Inline Markdown: emphasis, code spans, links and images, autolinks, footnote references, the safe HTML tags.
extension Renderer {
    /// `links: false` inside a link's text (no link in a link), `images: false` inside an image's alt.
    func inline(_ text: String, links: Bool = true, images: Bool = true) -> String {
        let chars = Array(text)
        var nodes: [Node] = [], buf = "", i = 0
        func flush() {
            if !buf.isEmpty {
                nodes.append(.html(buf))
                buf = ""
            }
        }
        while i < chars.count {
            let ch = chars[i]
            var piece: (html: String, end: Int)?
            switch ch {
            case "\\": piece = backslash(chars, i)
            case "`": piece = codeSpan(chars, i)
            case "*", "_", "~":
                let (node, end) = delimiterRun(chars, i)
                if let node {
                    flush()
                    nodes.append(node)
                } else {
                    buf += String(chars[i..<end])
                }
                i = end
                continue
            case "!" where images && i + 1 < chars.count && chars[i + 1] == "[":
                piece = link(chars, i, image: true) ?? ("!", i + 1)
            case "[" where links: piece = footnoteRef(chars, i) ?? link(chars, i, image: false) ?? ("[", i + 1)
            case "<": piece = angle(chars, i, links: links)
            case "&": piece = entity(chars, i)
            case "\n":
                let hard = buf.hasSuffix("  ")
                while buf.last == " " { buf.removeLast() }
                piece = (hard ? "<br>\n" : "\n", i + 1)
            case "h", "w": piece = links ? bareLink(chars, i) : nil
            case ">": piece = ("&gt;", i + 1)
            case "\"": piece = ("&quot;", i + 1)
            default: break
            }
            let (html, end) = piece ?? (String(ch), i + 1)
            buf += html
            i = end
        }
        flush()
        emphasis(&nodes)
        return nodes.map {
            switch $0 {
            case .html(let html): return html
            case .delim(let delim):
                return delim.post.joined() + String(repeating: delim.ch, count: delim.count) + delim.pre.joined()
            }
        }.joined()
    }

    // Each reads what starts at c[i] and returns its HTML and where the text goes on.

    /// `\` a hard break before a newline, else the punctuation it escapes.
    private func backslash(_ c: [Character], _ i: Int) -> (String, Int) {
        if i + 1 < c.count, c[i + 1] == "\n" { return ("<br>\n", i + 2) }
        if i + 1 < c.count, isASCIIPunct(c[i + 1]) { return (MarkdownHTML.esc(String(c[i + 1])), i + 2) }
        return ("\\", i + 1)
    }

    /// A code span: as many backticks closing it as opened it; unclosed, the backticks as text.
    private func codeSpan(_ c: [Character], _ i: Int) -> (String, Int) {
        var ticks = 0
        while i + ticks < c.count, c[i + ticks] == "`" { ticks += 1 }
        var pos = i + ticks, close: Int?
        while pos < c.count {
            guard c[pos] == "`" else {
                pos += 1
                continue
            }
            var run = 0
            while pos + run < c.count, c[pos + run] == "`" { run += 1 }
            if run == ticks {
                close = pos
                break
            }
            pos += run
        }
        guard let close else { return (String(repeating: "`", count: ticks), i + ticks) }
        var code = String(c[(i + ticks)..<close]).replacingOccurrences(of: "\n", with: " ")
        if code.count >= 2, code.first == " ", code.last == " ", !code.allSatisfy({ $0 == " " }) {
            code = String(code.dropFirst().dropLast())
        }
        return ("<code>\(MarkdownHTML.esc(code))</code>", close + ticks)
    }

    /// A run of `*`, `_` or `~`: a delimiter for `emphasis` (nil: three or more `~`, just text) and where it ends.
    private func delimiterRun(_ c: [Character], _ i: Int) -> (Node?, Int) {
        let ch = c[i]
        var end = i
        while end < c.count, c[end] == ch { end += 1 }
        let run = end - i
        if ch == "~", run > 2 { return (nil, end) }
        let prev: Character = i > 0 ? c[i - 1] : " ", next: Character = end < c.count ? c[end] : " "
        let pw = prev.isWhitespace, nw = next.isWhitespace, pp = isPunct(prev), np = isPunct(next)
        let left = !nw && (!np || pw || pp), right = !pw && (!pp || nw || np)
        let open = ch == "_" ? left && (!right || pp) : left, close = ch == "_" ? right && (!left || np) : right
        return (.delim(Delim(ch: ch, orig: run, count: run, open: open, close: close)), end)
    }

    /// `<`: an HTML comment (dropped), an autolink (`<https://…>`, `<a@b.c>`), a tag on the list, else `&lt;`.
    private func angle(_ c: [Character], _ i: Int, links: Bool) -> (String, Int) {
        if i + 3 < c.count, c[i + 1] == "!", c[i + 2] == "-", c[i + 3] == "-",
            let commentEnd = String(c[i...]).range(of: "-->")
        {
            return ("", i + String(c[i...])[..<commentEnd.upperBound].count)
        }
        if links, let close = c[(i + 1)...].firstIndex(of: ">") {
            let inner = String(c[(i + 1)..<close])
            if !inner.contains(where: { $0.isWhitespace || $0 == "<" }) {
                if inner.contains(":"), inner.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]{1,31}:.+/) != nil {
                    return ("<a href=\"\(MarkdownHTML.esc(safe(inner)))\">\(MarkdownHTML.esc(inner))</a>", close + 1)
                }
                if inner.contains("@"), inner.wholeMatch(of: /[^@\s]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)+/) != nil {
                    return ("<a href=\"mailto:\(MarkdownHTML.esc(inner))\">\(MarkdownHTML.esc(inner))</a>", close + 1)
                }
            }
        }
        return htmlTag(c, i) ?? ("&lt;", i + 1)
    }

    /// `&name;` / `&#123;` as is, else `&amp;`.
    private func entity(_ c: [Character], _ i: Int) -> (String, Int) {
        var end = i + 1
        while end < c.count, end - i < 33, c[end].isASCII, c[end].isLetter || c[end].isNumber || c[end] == "#" {
            end += 1
        }
        if end < c.count, end > i + 1, c[end] == ";" { return (String(c[i...end]), end + 1) }
        return ("&amp;", i + 1)
    }

    /// A bare `https://…`, `http://…` or `www.…` at a word's start, without the punctuation that ends a sentence.
    private func bareLink(_ c: [Character], _ i: Int) -> (String, Int)? {
        guard i == 0 || c[i - 1].isWhitespace || "(*_~\"'".contains(c[i - 1]) else { return nil }
        let head = String(c[i..<min(c.count, i + 8)]).lowercased()
        let plen = head.hasPrefix("https://") ? 8 : head.hasPrefix("http://") ? 7 : head.hasPrefix("www.") ? 4 : 0
        guard plen > 0 else { return nil }
        var end = i
        while end < c.count, !c[end].isWhitespace, !"<>\"`".contains(c[end]) { end += 1 }
        while end > i {
            let last = c[end - 1]
            if "?!.,:*_~'\";".contains(last) {
                end -= 1
                continue
            }
            if last == ")" {
                let candidate = c[i..<end]
                if candidate.filter({ $0 == "(" }).count < candidate.filter({ $0 == ")" }).count {
                    end -= 1
                    continue
                }
            }
            break
        }
        guard end - i > plen else { return nil }
        let url = String(c[i..<end])
        return (
            "<a href=\"\(MarkdownHTML.esc(plen == 4 ? "http://" + url : url))\">\(MarkdownHTML.esc(url))</a>", end
        )
    }

    /// CommonMark "process emphasis", minus the openers_bottom optimisation (O(n²) on pathological input).
    private func emphasis(_ nodes: inout [Node]) {
        var index = 0
        while index < nodes.count {
            guard case .delim(var closer) = nodes[index], closer.close, closer.count > 0 else {
                index += 1
                continue
            }
            var found: Int?
            for candidate in stride(from: index - 1, through: 0, by: -1) {
                guard case .delim(let opener) = nodes[candidate], opener.ch == closer.ch, opener.open, opener.count > 0
                else { continue }
                if closer.ch == "~" {
                    if opener.count == closer.count {
                        found = candidate
                        break
                    } else {
                        continue
                    }
                }
                if opener.close || closer.open, (opener.orig + closer.orig) % 3 == 0,
                    !(opener.orig % 3 == 0 && closer.orig % 3 == 0)
                {
                    continue
                }
                found = candidate
                break
            }
            guard let start = found, case .delim(var opener) = nodes[start] else {
                index += 1
                continue
            }
            let width = closer.ch == "~" ? closer.count : (opener.count >= 2 && closer.count >= 2 ? 2 : 1)
            let tag = closer.ch == "~" ? "del" : width == 2 ? "strong" : "em"
            opener.count -= width
            closer.count -= width
            opener.pre.insert("<\(tag)>", at: 0)
            closer.post.append("</\(tag)>")
            nodes[start] = .delim(opener)
            nodes[index] = .delim(closer)
            for between in (start + 1)..<index {
                if case .delim(var delim) = nodes[between] {
                    delim.open = false
                    delim.close = false
                    nodes[between] = .delim(delim)
                }
            }
            if closer.count == 0 { index += 1 }
        }
    }

    private func link(_ c: [Character], _ i: Int, image: Bool) -> (String, Int)? {
        let textStart = image ? i + 1 : i
        var depth = 0, k = textStart, close: Int?
        while k < c.count {
            if c[k] == "\\" {
                k += 2
                continue
            }
            if c[k] == "[" {
                depth += 1
            } else if c[k] == "]" {
                depth -= 1
                if depth == 0 {
                    close = k
                    break
                }
            }
            k += 1
        }
        guard let cl = close else { return nil }
        let text = String(c[(textStart + 1)..<cl])
        var dest: String?, title: String?, end = cl + 1
        if end < c.count, c[end] == "(", let inlineDest = destination(c, end + 1) {
            dest = inlineDest.0
            title = inlineDest.1
            end = inlineDest.2
        } else {
            var label = text, after = end
            if end < c.count, c[end] == "[", let labelEnd = c[(end + 1)...].firstIndex(of: "]") {
                let written = String(c[(end + 1)..<labelEnd])
                if !written.isEmpty { label = written }
                after = labelEnd + 1
            }
            if let ref = refs[norm(label)] {
                dest = ref.url
                title = ref.title
                end = after
            }
        }
        guard let dest else { return nil }
        let titleAttr = title.map { " title=\"\(MarkdownHTML.esc($0))\"" } ?? ""
        let inner = inline(text, links: false, images: !image)   // a badge: `[![alt](img)](link)`
        if image {
            return (
                "<img src=\"\(MarkdownHTML.esc(safe(dest, image: true)))\" alt=\"\(stripTags(inner))\"\(titleAttr)>",
                end
            )
        }
        return ("<a href=\"\(MarkdownHTML.esc(safe(dest)))\"\(titleAttr)>\(inner)</a>", end)
    }

    private func destination(_ c: [Character], _ start: Int) -> (String, String?, Int)? {
        var pos = start, url = ""
        func ws() { while pos < c.count, c[pos] == " " || c[pos] == "\n" { pos += 1 } }
        ws()
        if pos < c.count, c[pos] == "<" {
            pos += 1
            while pos < c.count, c[pos] != ">", c[pos] != "\n" {
                url.append(c[pos])
                pos += 1
            }
            guard pos < c.count, c[pos] == ">" else { return nil }
            pos += 1
        } else {
            var depth = 0
            while pos < c.count, !c[pos].isWhitespace {
                if c[pos] == "\\", pos + 1 < c.count, isASCIIPunct(c[pos + 1]) {
                    url.append(c[pos + 1])
                    pos += 2
                    continue
                }
                if c[pos] == "(" {
                    depth += 1
                } else if c[pos] == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                url.append(c[pos])
                pos += 1
            }
        }
        ws()
        var title: String?
        let quotes: [Character: Character] = ["\"": "\"", "'": "'", "(": ")"]
        if pos < c.count, let closeQuote = quotes[c[pos]] {
            var quoted = ""
            pos += 1
            while pos < c.count, c[pos] != closeQuote {
                if c[pos] == "\\", pos + 1 < c.count {
                    quoted.append(c[pos + 1])
                    pos += 2
                    continue
                }
                quoted.append(c[pos])
                pos += 1
            }
            guard pos < c.count else { return nil }
            pos += 1
            title = quoted
            ws()
        }
        guard pos < c.count, c[pos] == ")" else { return nil }
        return (url.replacingOccurrences(of: " ", with: "%20"), title, pos + 1)
    }

    /// Neutralises script-capable URL schemes.
    func safe(_ url: String, image: Bool = false) -> String {
        let lower = url.lowercased().filter { !$0.isWhitespace && !($0.asciiValue.map { $0 < 32 } ?? false) }
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:")
            || (lower.hasPrefix("data:") && !(image && lower.hasPrefix("data:image/")))
        {
            return "#"
        }
        return url
    }

    func stripTags(_ html: String) -> String {
        var out = "", tag = false
        for char in html {
            if char == "<" { tag = true } else if char == ">" { tag = false } else if !tag { out.append(char) }
        }
        return out
    }

    private func isASCIIPunct(_ char: Character) -> Bool { char.isASCII && (char.isPunctuation || char.isSymbol) }
    private func isPunct(_ char: Character) -> Bool { char.isPunctuation || char.isSymbol }
}
