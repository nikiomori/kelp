import Core
import Foundation
import KelpKit
import Markdown

/// A pull request's or an issue's page in its tab: title, who and when, what stands in the way, the description in
/// Markdown and the conversation; beside it a PR's checks and files. Other people's words go through `MarkdownHTML`,
/// which escapes raw HTML.
@MainActor
enum ForgePage {
    static func pr(_ view: GitHub.PRView, checks: [GitHub.Check]?, block: String?) -> String {
        let pr = view.pr
        let state = pr.isDraft ? ("draft", String(localized: "Draft")) : stateWords(pr.state)
        var meta = [esc(pr.author)]
        if let updated = pr.updatedAt.map(CIRunLook.ago), !updated.isEmpty {
            meta.append(String(localized: "updated \(updated) ago"))
        }
        meta.append(esc(pr.headRefName) + " → " + esc(view.baseRefName))
        let main =
            header(pr.title, number: pr.number, state: state, meta: meta, block: block)
            + description(view.body) + conversation(view.comments)
        return columns(main, side: checksList(checks) + filesList(view.files))
    }

    static func issue(_ view: GitHub.IssueView, working: String?) -> String {
        let issue = view.issue
        var meta: [String] = []
        if let author = issue.author { meta.append(esc(author)) }
        if let updated = issue.updatedAt.map(CIRunLook.ago), !updated.isEmpty {
            meta.append(String(localized: "updated \(updated) ago"))
        }
        if !issue.labels.isEmpty { meta.append(esc(issue.labels.joined(separator: ", "))) }
        let block = working.map { String(localized: "In work on \($0).") }
        let main =
            header(
                issue.title, number: issue.number, state: stateWords(issue.state), meta: meta, block: block, quiet: true
            )
            + description(issue.body) + conversation(view.comments)
        return "<div class=\"main solo\">\(main)</div>" + css
    }

    private static func stateWords(_ state: String) -> (String, String) {
        switch state {
        case "MERGED": ("merged", String(localized: "Merged"))
        case "CLOSED": ("closed", String(localized: "Closed"))
        default: ("open", String(localized: "Open"))
        }
    }

    private static func header(
        _ title: String, number: Int, state: (String, String), meta: [String], block: String?, quiet: Bool = false
    ) -> String {
        """
        <h1 class="title">\(esc(title)) <span class="num">#\(number)</span></h1>
        <p class="meta"><span class="state \(state.0)">\(esc(state.1))</span> \(meta.joined(separator: " · "))</p>
        \(block.map { "<p class=\"block\(quiet ? " quiet" : "")\">\(esc($0))</p>" } ?? "")
        """
    }

    private static func description(_ body: String) -> String {
        body.isEmpty
            ? "<p class=\"none\">\(esc(String(localized: "No description.")))</p>"
            : MarkdownHTML.render(String(body.prefix(60_000)))
    }

    private static func conversation(_ comments: [GitHub.Comment]) -> String {
        guard !comments.isEmpty else { return "" }
        let items = comments.map { comment in
            let verdict: String =
                switch comment.review {
                case "APPROVED": String(localized: "approved")
                case "CHANGES_REQUESTED": String(localized: "asked for changes")
                case "COMMENTED": String(localized: "reviewed")
                default: ""
                }
            let when = CIRunLook.ago(comment.createdAt)
            let head = [esc(comment.author) + (verdict.isEmpty ? "" : " " + esc(verdict)), when.isEmpty ? "" : when]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            let body = comment.body.isEmpty ? "" : MarkdownHTML.render(String(comment.body.prefix(20_000)))
            return "<div class=\"comment\"><p class=\"who\">\(head)</p>\(body)</div>"
        }
        return "<h2>\(esc(String(localized: "Conversation")))</h2>" + items.joined()
    }

    private static func checksList(_ checks: [GitHub.Check]?) -> String {
        guard let checks else { return "" }
        let failed = checks.filter { $0.bucket == "fail" }.count
        let title =
            checks.isEmpty
            ? String(localized: "Checks")
            : failed > 0
                ? String(localized: "Checks · \(failed) failing") : String(localized: "Checks · \(checks.count)")
        let rows = checks.map { check -> String in
            let mark =
                switch check.bucket {
                case "pass": "<span class=\"pass\">✓</span>"
                case "fail": "<span class=\"fail\">✕</span>"
                case "pending": "<span class=\"wait\">◌</span>"
                default: "<span class=\"wait\">–</span>"
                }
            return "<li>\(mark) \(esc(check.name))</li>"
        }
        let none = checks.isEmpty ? "<li class=\"none\">\(esc(String(localized: "No checks reported.")))</li>" : ""
        return "<h3>\(esc(title))</h3><ul class=\"side\">\(rows.joined())\(none)</ul>"
    }

    private static func filesList(_ files: [GitHub.ChangedFile]) -> String {
        guard !files.isEmpty else { return "" }
        let rows = files.prefix(100).map { file -> String in
            let name = (file.path as NSString).lastPathComponent
            let added = file.additions > 0 ? "<span class=\"pass\">+\(file.additions)</span>" : ""
            let removed = file.deletions > 0 ? "<span class=\"fail\">−\(file.deletions)</span>" : ""
            return "<li title=\"\(esc(file.path))\"><span class=\"file\">\(esc(name))</span> \(added) \(removed)</li>"
        }
        let more = files.count > 100 ? "<li class=\"none\">+\(files.count - 100)</li>" : ""
        return
            "<h3>\(esc(String(localized: "Files · \(files.count)")))</h3>"
            + "<ul class=\"side\">\(rows.joined())\(more)</ul>"
    }

    private static func columns(_ main: String, side: String) -> String {
        "<div class=\"cols\"><div class=\"main\">\(main)</div><aside>\(side)</aside></div>" + css
    }

    private static func esc(_ text: String) -> String { MarkdownHTML.esc(text) }

    private static let css = """
        <style>
        .markdown-body{max-width:1080px;padding:20px 24px 48px;font-size:14px}
        .cols{display:flex;gap:32px;align-items:flex-start}.main{flex:1;min-width:0}.main.solo{max-width:820px}
        aside{width:240px;flex:none;font-size:12px;position:sticky;top:0}
        @media (max-width:720px){.cols{display:block}aside{width:auto;position:static}}
        h1.title{font-size:20px;border:0;margin:0 0 6px;padding:0}.num{color:var(--muted);font-weight:400}
        .meta{color:var(--muted);font-size:12px;margin:0 0 10px}
        .state{display:inline-block;padding:0 7px;border-radius:9px;border:1px solid currentColor;font-size:11px}
        .state.open{color:var(--tip)}.state.draft{color:var(--muted)}.state.merged{color:var(--important)}
        .state.closed{color:var(--caution)}
        .block{color:var(--warning);font-size:13px;margin:0 0 14px}.block.quiet{color:var(--muted)}
        .none{color:var(--muted)}
        h2{font-size:14px;border:0;margin:28px 0 8px}
        h3{font-size:11px;text-transform:uppercase;color:var(--muted);margin:0 0 6px;letter-spacing:.02em}
        ul.side{list-style:none;padding:0;margin:0 0 18px}ul.side li{margin:0 0 3px;display:flex;gap:6px}
        .file{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .pass{color:var(--tip)}.fail{color:var(--caution)}.wait{color:var(--muted)}
        .comment{border-top:1px solid var(--border);padding:10px 0 2px}
        .comment .who{color:var(--muted);font-size:12px;margin:0 0 6px}
        </style>
        """
}
