import AppKit
import Core
import DesignKit
import KelpKit
import Markdown

/// A task's page ends with what grew from the task, as Craft's Links to This Page: where its line is, the issue it
/// came from, and each chat with what it does, its branch and its pull request. It shows only on a page a task grew
/// into, once there is something to say. The project's tasks are watched while the page is open, and the block follows
/// them.
extension MarkdownTab {
    /// The page's task rows, from its project's watch (started here, see `linkedBlock`).
    private func taskRows() -> [TaskRow] {
        let path = url.standardizedFileURL.path
        guard let repo = app.repos.first(where: { path.hasPrefix(Artifacts.dir(root: $0.path).path + "/") }) else {
            return []
        }
        return TaskViews.rows([(repo.id, app.latest(TasksEvent.self, repo.id)?.pages ?? [])], session: app.session)
    }

    /// The task on `line` of this page.
    func taskRow(line: Int) -> TaskRow? {
        let path = url.standardizedFileURL.path
        return taskRows().first { $0.page.path == path && $0.task.line == line }
    }

    /// What each task line of the page shows beside its box, as the Tasks tab's row does: what its agent does (orange
    /// when it asks), and, under the pointer, ▶ for a line no agent works on.
    func taskScript() -> String? {
        let path = url.standardizedFileURL.path, agent = app.catalog.name(TaskActions.lastAgent(app))
        struct Mark: Encodable { var w: String, o: Bool, run: Bool, t: String }
        var marks: [String: Mark] = [:]
        for row in taskRows() where row.page.path == path && row.task.state == .open {
            let chats = (row.task.chats ?? []).compactMap(app.session)
            let word = TaskCell.word(row, chats.last)
            let run = row.task.proposed != true && (row.work == .none || row.work == .review)
            guard !word.isEmpty || run else { continue }
            marks[String(row.task.line)] = Mark(
                w: word, o: row.work == .asks || row.task.proposed == true, run: run,
                t: String(localized: "Do with \(agent)"))
        }
        guard !marks.isEmpty else { return nil }
        return """
            (function () {
              const marks = \(Self.js(marks));
              for (const box of document.querySelectorAll('input[data-task]')) {
                const m = marks[box.dataset.task], at = box.parentElement;
                if (!m || !at) continue;
                if (m.w) {
                  const s = document.createElement('span');
                  s.textContent = ' · ' + m.w;
                  s.style.cssText = 'font-size:.85em;' + (m.o ? 'color:#c76b00;font-weight:600' : 'opacity:.6');
                  at.appendChild(s);
                }
                if (m.run) {
                  const b = document.createElement('button');
                  b.textContent = '▶'; b.title = m.t;
                  b.style.cssText = 'margin-left:.4em;border:0;background:none;cursor:pointer;opacity:0;' +
                    'font-size:.8em;color:var(--k-accent,#007aff);transition:opacity .12s';
                  const li = box.closest('li') || at;
                  li.addEventListener('mouseenter', () => b.style.opacity = 1);
                  li.addEventListener('mouseleave', () => b.style.opacity = 0);
                  b.onclick = e => {
                    e.preventDefault();
                    window.webkit.messageHandlers.kelpSync.postMessage({ kind: 'taskRun', line: +box.dataset.task });
                  };
                  at.appendChild(b);
                }
              }
            })();
            """
    }

    /// The block's HTML, or "" for any other page.
    func linkedBlock() -> String {
        let path = url.standardizedFileURL.path
        guard path.contains("/\(Artifacts.folder)/"),
            let repo = app.repos.first(where: { path.hasPrefix(Artifacts.dir(root: $0.path).path + "/") })
        else { return "" }
        if tasksWatch == nil {
            let watch = Watched(.tasks, in: app)
            watch.key = repo.id
            tasksWatch = watch
            // The page's lines and what their chats do: a mark that changes draws the page again.
            track(owner: self, now: false) { [app] in
                let pages = app.latest(TasksEvent.self, repo.id)
                let chats = pages?.pages.flatMap { $0.tasks.flatMap { $0.chats ?? [] } } ?? []
                return Values(pages, chats.compactMap { app.session($0)?.status })
            } changed: { [weak self] _ in
                self?.rerender()
            }
        }
        let rows = TaskViews.rows([(repo.id, app.latest(TasksEvent.self, repo.id)?.pages ?? [])], session: app.session)
        guard let row = rows.first(where: { $0.task.page != nil && TaskActions.pageFile($0) == path }) else {
            return ""
        }
        var items = [String(localized: "On \(row.page.title) › \(row.place)")]
        if let issue = row.task.issue {
            items.append("<a href=\"\(MarkdownHTML.esc(issue))\">\(MarkdownHTML.esc(row.task.issueRef ?? issue))</a>")
        }
        let prs = app.latest(PRsEvent.self, repo.id)?.prs ?? []
        for chat in (row.task.chats ?? []).compactMap(app.session) {
            var said = [app.catalog.name(chat.agent), chat.displayTitle, chat.status.words]
            if let branch = app.worktree(chat.worktreeId)?.branch, !branch.isEmpty {
                said.append(branch)
                if let pr = prs.first(where: { $0.headRefName == branch }) { said.append("PR #\(pr.number)") }
            }
            items.append(MarkdownHTML.esc(said.joined(separator: " · ")))
        }
        let list = items.map { "<li>\($0)</li>" }.joined()
        return """
            <section class="k-linked" style="margin-top:2.5em;padding-top:1em;border-top:1px solid \
            rgba(127,127,127,.25);font-size:.92em;opacity:.85"><h4 style="margin:0 0 .4em">\
            \(MarkdownHTML.esc(String(localized: "Linked")))</h4><ul style="margin:0">\(list)</ul></section>
            """
    }
}
