import AppKit
import Core
import WorkbenchKit

/// What the first character of ⌘P's field asks for: ":120" a line, "/name" (or "file:name") files alone, "@name" the symbols
/// of the file on screen. ">" and "#" are the commands' and the pull requests'.
extension QuickOpen {
    enum Prefix: Equatable {
        case line(Int?), files(String), symbols(String)

        init?(_ q: String) {
            if q.hasPrefix(":") {
                self = .line(q.dropFirst().split(separator: ":", omittingEmptySubsequences: false).first.flatMap { Int($0) })
            } else if q.hasPrefix("/") {
                self = .files(String(q.dropFirst()))
            } else if q.lowercased().hasPrefix("file:") {
                self = .files(String(q.dropFirst(5)))
            } else if q.hasPrefix("@") {
                self = .symbols(String(q.dropFirst()))
            } else {
                return nil
            }
        }
    }

    /// True when the prefix took it. `/` goes on through the usual scoring, with files alone.
    func filterPrefix(_ prefix: Prefix) -> Bool {
        switch prefix {
        case .files: return false
        case .line(let n): listLine(n)
        case .symbols(let q): listSymbols(q)
        }
        return true
    }

    /// The editor goes there as you type, as it would on ↩.
    private func listLine(_ n: Int?) {
        let tab = app.workbench.editor?.focusedContent
        guard let n, n > 0, tab?.fileURL != nil else {
            setRows([], grouped: false, heading: String(localized: tab?.fileURL == nil ? "No file on screen" : "Type a line number"))
            return
        }
        tab?.goTo(line: n)
        field.window?.makeFirstResponder(field)
        let item = Item(kind: "Line", icon: "arrow.right.to.line", title: String(localized: "Go to Line \(n)"), detail: "",
                        action: { [weak tab] in tab?.goTo(line: n) })
        setRows([item], grouped: false)
    }

    private func listSymbols(_ q: String) {
        guard let url = app.workbench.editor?.focusedContent?.fileURL else {
            setRows([], grouped: false, heading: String(localized: "No file on screen"))
            return
        }
        if let known = symbols, known.path == url.path { showSymbols(known.items, q); return }
        let app = self.app, path = url.path
        let root = app.worktrees.filter { path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }?.path ?? url.deletingLastPathComponent().path
        symbolLoad?.cancel()
        symbolLoad = Task { [weak self] in
            var found = await app.quiet(LSPSymbols(root: root, path: path)) ?? []
            if found.isEmpty, ["md", "markdown"].contains(url.pathExtension.lowercased()), let text = await app.quiet(FilesRead(path: path))?.text {
                found = Self.headings(text)
            }
            guard let self, !Task.isCancelled else { return }
            let tab = app.workbench.editor?.focusedContent
            symbols = (path, found.map { s in
                Item(kind: "Symbol", icon: "number", title: s.name, detail: s.kind, action: { [weak tab] in tab?.goTo(line: s.line) })
            })
            if case .symbols(let now)? = Prefix(field.stringValue), let items = symbols?.items { showSymbols(items, now) }
        }
    }

    private func showSymbols(_ items: [Item], _ q: String) {
        let found = q.isEmpty ? items : items.filter { Self.wordScore($0.title, q) != nil }
        setRows(found, grouped: false, heading: found.isEmpty ? String(localized: "No symbols") : nil)
    }

    /// A Markdown file's headings, which no language server lists. `#` inside a code block isn't one.
    nonisolated static func headings(_ text: String) -> [CodeSymbol] {
        var out: [CodeSymbol] = [], fenced = false
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.hasPrefix("```") { fenced.toggle() }
            guard !fenced, line.hasPrefix("#") else { continue }
            let level = line.prefix { $0 == "#" }.count, rest = line.dropFirst(level)
            guard level <= 6, rest.hasPrefix(" ") else { continue }
            out.append(CodeSymbol(name: rest.trimmingCharacters(in: .whitespaces), kind: "h\(level)", line: i + 1))
        }
        return out
    }

    /// "#123" or "#login": the project's open pull requests (gh), opened in the browser tab.
    func searchPullRequests(_ q: String) {
        let app = self.app
        prSearch?.cancel()
        guard let repo = app.worktree(app.workbench.workspaceId)?.repoId else { return }
        prSearch = Task { [weak self] in
            let prs = await app.call(GitHubPRs(repoId: repo, filter: "open")) ?? []   // gh missing or signed out: says so
            guard let self, !Task.isCancelled, field.stringValue == q else { return }
            let term = String(q.dropFirst()).lowercased()
            setRows(prs.filter { p in term.isEmpty || "\(p.number)".hasPrefix(term) || p.title.lowercased().contains(term) }.map { p in
                Item(kind: "Pull Request", icon: "arrow.triangle.pull", title: "#\(p.number) \(p.title)",
                     detail: "\(p.author) · \(p.headRefName)", action: { app.workbench.open(p.url) })
            }, grouped: false)
        }
    }

    /// A title matches when it contains the query, or each query word starts a word of the title.
    nonisolated static func wordScore(_ title: String, _ query: String) -> Int? {
        let t = title.lowercased(), q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        if t.hasPrefix(q) { return 100 }
        let words = t.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.contains(where: { $0.hasPrefix(q) }) { return 80 }
        if t.contains(q) { return 60 }
        let parts = q.split(separator: " ").map(String.init)
        return parts.count > 1 && parts.allSatisfy({ p in words.contains { $0.hasPrefix(p) } }) ? 40 : nil
    }
}
