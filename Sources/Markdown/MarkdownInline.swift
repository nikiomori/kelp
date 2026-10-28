import Foundation

/// Inline Markdown: emphasis, code spans, links and images, autolinks, footnote references, the safe HTML tags.
extension Renderer {
    /// `links: false` inside a link's text (no link in a link), `images: false` inside an image's alt.
    func inline(_ s: String, links: Bool = true, images: Bool = true) -> String {
        let c = Array(s)
        var nodes: [Node] = [], buf = "", i = 0
        func flush() { if !buf.isEmpty { nodes.append(.html(buf)); buf = "" } }
        while i < c.count {
            let ch = c[i]
            var piece: (html: String, end: Int)?
            switch ch {
            case "\\": piece = backslash(c, i)
            case "`": piece = codeSpan(c, i)
            case "*", "_", "~":
                let (node, end) = delimiterRun(c, i)
                if let node { flush(); nodes.append(node) } else { buf += String(c[i..<end]) }
                i = end; continue
            case "!" where images && i + 1 < c.count && c[i + 1] == "[": piece = link(c, i, image: true) ?? ("!", i + 1)
            case "[" where links: piece = footnoteRef(c, i) ?? link(c, i, image: false) ?? ("[", i + 1)
            case "<": piece = angle(c, i, links: links)
            case "&": piece = entity(c, i)
            case "\n":
                let hard = buf.hasSuffix("  ")
                while buf.last == " " { buf.removeLast() }
                piece = (hard ? "<br>\n" : "\n", i + 1)
            case "h", "w": piece = links ? bareLink(c, i) : nil
            case ">": piece = ("&gt;", i + 1)
            case "\"": piece = ("&quot;", i + 1)
            default: break
            }
            let (html, end) = piece ?? (String(ch), i + 1)
            buf += html; i = end
        }
        flush()
        emphasis(&nodes)
        return nodes.map {
            switch $0 {
            case .html(let h): return h
            case .delim(let d): return d.post.joined() + String(repeating: d.ch, count: d.count) + d.pre.joined()
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
        var n = 0
        while i + n < c.count, c[i + n] == "`" { n += 1 }
        var k = i + n, close: Int?
        while k < c.count {
            guard c[k] == "`" else { k += 1; continue }
            var m = 0
            while k + m < c.count, c[k + m] == "`" { m += 1 }
            if m == n { close = k; break }
            k += m
        }
        guard let f = close else { return (String(repeating: "`", count: n), i + n) }
        var code = String(c[(i + n)..<f]).replacingOccurrences(of: "\n", with: " ")
        if code.count >= 2, code.first == " ", code.last == " ", !code.allSatisfy({ $0 == " " }) { code = String(code.dropFirst().dropLast()) }
        return ("<code>\(MarkdownHTML.esc(code))</code>", f + n)
    }

    /// A run of `*`, `_` or `~`: a delimiter for `emphasis` (nil: three or more `~`, just text) and where it ends.
    private func delimiterRun(_ c: [Character], _ i: Int) -> (Node?, Int) {
        let ch = c[i]
        var e = i
        while e < c.count, c[e] == ch { e += 1 }
        let run = e - i
        if ch == "~", run > 2 { return (nil, e) }
        let prev: Character = i > 0 ? c[i - 1] : " ", next: Character = e < c.count ? c[e] : " "
        let pw = prev.isWhitespace, nw = next.isWhitespace, pp = isPunct(prev), np = isPunct(next)
        let left = !nw && (!np || pw || pp), right = !pw && (!pp || nw || np)
        let open = ch == "_" ? left && (!right || pp) : left, close = ch == "_" ? right && (!left || np) : right
        return (.delim(Delim(ch: ch, orig: run, count: run, open: open, close: close)), e)
    }

    /// `<`: an HTML comment (dropped), an autolink (`<https://…>`, `<a@b.c>`), a tag on the list, else `&lt;`.
    private func angle(_ c: [Character], _ i: Int, links: Bool) -> (String, Int) {
        if i + 3 < c.count, c[i + 1] == "!", c[i + 2] == "-", c[i + 3] == "-", let r = String(c[i...]).range(of: "-->") {
            return ("", i + String(c[i...])[..<r.upperBound].count)
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
        var k = i + 1
        while k < c.count, k - i < 33, c[k].isASCII, c[k].isLetter || c[k].isNumber || c[k] == "#" { k += 1 }
        if k < c.count, k > i + 1, c[k] == ";" { return (String(c[i...k]), k + 1) }
        return ("&amp;", i + 1)
    }

    /// A bare `https://…`, `http://…` or `www.…` at a word's start, without the punctuation that ends a sentence.
    private func bareLink(_ c: [Character], _ i: Int) -> (String, Int)? {
        guard i == 0 || c[i - 1].isWhitespace || "(*_~\"'".contains(c[i - 1]) else { return nil }
        let head = String(c[i..<min(c.count, i + 8)]).lowercased()
        let plen = head.hasPrefix("https://") ? 8 : head.hasPrefix("http://") ? 7 : head.hasPrefix("www.") ? 4 : 0
        guard plen > 0 else { return nil }
        var e = i
        while e < c.count, !c[e].isWhitespace, !"<>\"`".contains(c[e]) { e += 1 }
        while e > i {
            let last = c[e - 1]
            if "?!.,:*_~'\";".contains(last) { e -= 1; continue }
            if last == ")" {
                let u = c[i..<e]
                if u.filter({ $0 == "(" }).count < u.filter({ $0 == ")" }).count { e -= 1; continue }
            }
            break
        }
        guard e - i > plen else { return nil }
        let url = String(c[i..<e])
        return ("<a href=\"\(MarkdownHTML.esc(plen == 4 ? "http://" + url : url))\">\(MarkdownHTML.esc(url))</a>", e)
    }

    /// CommonMark "process emphasis", minus the openers_bottom optimisation (O(n²) on pathological input).
    private func emphasis(_ nodes: inout [Node]) {
        var i = 0
        while i < nodes.count {
            guard case .delim(var c) = nodes[i], c.close, c.count > 0 else { i += 1; continue }
            var found: Int?
            for j in stride(from: i - 1, through: 0, by: -1) {
                guard case .delim(let o) = nodes[j], o.ch == c.ch, o.open, o.count > 0 else { continue }
                if c.ch == "~" { if o.count == c.count { found = j; break } else { continue } }
                if o.close || c.open, (o.orig + c.orig) % 3 == 0, !(o.orig % 3 == 0 && c.orig % 3 == 0) { continue }
                found = j; break
            }
            guard let j = found, case .delim(var o) = nodes[j] else { i += 1; continue }
            let n = c.ch == "~" ? c.count : (o.count >= 2 && c.count >= 2 ? 2 : 1)
            let tag = c.ch == "~" ? "del" : n == 2 ? "strong" : "em"
            o.count -= n; c.count -= n
            o.pre.insert("<\(tag)>", at: 0); c.post.append("</\(tag)>")
            nodes[j] = .delim(o); nodes[i] = .delim(c)
            for k in (j + 1)..<i { if case .delim(var d) = nodes[k] { d.open = false; d.close = false; nodes[k] = .delim(d) } }
            if c.count == 0 { i += 1 }
        }
    }

    private func link(_ c: [Character], _ i: Int, image: Bool) -> (String, Int)? {
        let b = image ? i + 1 : i
        var depth = 0, k = b, close: Int?
        while k < c.count {
            if c[k] == "\\" { k += 2; continue }
            if c[k] == "[" { depth += 1 } else if c[k] == "]" { depth -= 1; if depth == 0 { close = k; break } }
            k += 1
        }
        guard let cl = close else { return nil }
        let text = String(c[(b + 1)..<cl])
        var dest: String?, title: String?, end = cl + 1
        if end < c.count, c[end] == "(", let d = destination(c, end + 1) {
            dest = d.0; title = d.1; end = d.2
        } else {
            var label = text, after = end
            if end < c.count, c[end] == "[", let m = c[(end + 1)...].firstIndex(of: "]") {
                let l = String(c[(end + 1)..<m])
                if !l.isEmpty { label = l }
                after = m + 1
            }
            if let r = refs[norm(label)] { dest = r.url; title = r.title; end = after }
        }
        guard let d = dest else { return nil }
        let t = title.map { " title=\"\(MarkdownHTML.esc($0))\"" } ?? ""
        let inner = inline(text, links: false, images: !image)   // a badge: `[![alt](img)](link)`
        if image { return ("<img src=\"\(MarkdownHTML.esc(safe(d, image: true)))\" alt=\"\(stripTags(inner))\"\(t)>", end) }
        return ("<a href=\"\(MarkdownHTML.esc(safe(d)))\"\(t)>\(inner)</a>", end)
    }

    private func destination(_ c: [Character], _ start: Int) -> (String, String?, Int)? {
        var k = start, d = ""
        func ws() { while k < c.count, c[k] == " " || c[k] == "\n" { k += 1 } }
        ws()
        if k < c.count, c[k] == "<" {
            k += 1
            while k < c.count, c[k] != ">", c[k] != "\n" { d.append(c[k]); k += 1 }
            guard k < c.count, c[k] == ">" else { return nil }
            k += 1
        } else {
            var depth = 0
            while k < c.count, !c[k].isWhitespace {
                if c[k] == "\\", k + 1 < c.count, isASCIIPunct(c[k + 1]) { d.append(c[k + 1]); k += 2; continue }
                if c[k] == "(" { depth += 1 } else if c[k] == ")" { if depth == 0 { break }; depth -= 1 }
                d.append(c[k]); k += 1
            }
        }
        ws()
        var title: String?
        let quotes: [Character: Character] = ["\"": "\"", "'": "'", "(": ")"]
        if k < c.count, let q = quotes[c[k]] {
            var t = ""
            k += 1
            while k < c.count, c[k] != q {
                if c[k] == "\\", k + 1 < c.count { t.append(c[k + 1]); k += 2; continue }
                t.append(c[k]); k += 1
            }
            guard k < c.count else { return nil }
            k += 1; title = t; ws()
        }
        guard k < c.count, c[k] == ")" else { return nil }
        return (d.replacingOccurrences(of: " ", with: "%20"), title, k + 1)
    }

    /// Neutralises script-capable URL schemes.
    func safe(_ u: String, image: Bool = false) -> String {
        let l = u.lowercased().filter { !$0.isWhitespace && !($0.asciiValue.map { $0 < 32 } ?? false) }
        if l.hasPrefix("javascript:") || l.hasPrefix("vbscript:") || (l.hasPrefix("data:") && !(image && l.hasPrefix("data:image/"))) { return "#" }
        return u
    }

    func stripTags(_ h: String) -> String {
        var o = "", tag = false
        for c in h { if c == "<" { tag = true } else if c == ">" { tag = false } else if !tag { o.append(c) } }
        return o
    }

    private func isASCIIPunct(_ c: Character) -> Bool { c.isASCII && (c.isPunctuation || c.isSymbol) }
    private func isPunct(_ c: Character) -> Bool { c.isPunctuation || c.isSymbol }
}
