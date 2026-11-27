import Core
import Foundation

/// Turns conversations (`WorkLog`) into where an agent worked (`AgentWork`): which files of its project it read and
/// edited, what it reached outside, and its steps, for one turn or the whole session. A turn runs from one prompt of
/// the session's own agent to the next; the subagents' and started agents' calls fall into the turn their time does.
public enum WorkMap {
    /// One conversation and whose it is.
    public struct Source: Sendable {
        public var agent: AgentWork.Agent
        public var log: WorkLog
        /// For a subagent: the id of its parent's call that started it (Claude Code's `.meta.json` `toolUseId`).
        public var startedBy: String?
        public init(agent: AgentWork.Agent, log: WorkLog, startedBy: String? = nil) {
            self.agent = agent
            self.log = log
            self.startedBy = startedBy
        }
    }

    /// Where the agent's machine keeps things: the project, the home folder, temporary folders.
    public struct Places: Sendable {
        public var root: String, home: String
        static let temporary = ["/tmp", "/private/tmp", "/var/folders"]
        /// The host of the project's `origin` (github.com): where `git push` and `gh` go, one place for both.
        public var remote: String?
        public init(root: String, home: String, remote: String? = nil) {
            self.root = root
            self.home = home
            self.remote = remote
        }
    }

    /// A file the turn's snapshot shows changed (path from the root), whoever changed it.
    public struct Changed: Sendable, Equatable {
        public var path: String, added: Int, removed: Int
        public init(path: String, added: Int, removed: Int) {
            self.path = path
            self.added = added
            self.removed = removed
        }
    }

    public static func build(
        _ sources: [Source], places: Places, turn: Int?, whole: Bool, working: Bool, changed: [Changed] = []
    ) -> AgentWork {
        var work = AgentWork()
        work.root = places.root
        work.agents = sources.map(\.agent)
        guard let main = sources.first else { return work }
        let prompts = main.log.prompts
        work.turns = prompts.map { AgentWork.Turn(prompt: JSONL.clip($0.text, 200), at: $0.at) }
        let picked =
            whole ? nil : (turn.map { min(max($0, 0), max(prompts.count - 1, 0)) } ?? max(prompts.count - 1, 0))
        work.turn = whole || prompts.isEmpty ? nil : picked
        let window: Range<Date> = {
            guard let picked, !prompts.isEmpty else { return Date.distantPast..<Date.distantFuture }
            let end = picked + 1 < prompts.count ? prompts[picked + 1].at : Date.distantFuture
            return prompts[picked].at..<max(end, prompts[picked].at.addingTimeInterval(0.001))
        }()
        var builder = Builder(places: places)
        var last: (at: Date, place: Int?)?
        for (index, source) in sources.enumerated() {
            for call in source.log.calls where window.contains(call.at) {
                let touched = builder.add(call, agent: index, steps: !whole)
                if call.at >= (last?.at ?? .distantPast) { last = (call.at, touched ?? last?.place) }
            }
        }
        if !whole {
            linkSubagents(sources, window: window, into: &builder)
            for change in changed { builder.changedByCommand(change) }
        }
        work.places = builder.places
        work.steps = builder.steps.sorted { $0.at < $1.at }
        work.now = working ? last?.place : nil
        return work
    }

    /// A spawn step points at the subagent it started, and a subagent whose parent's call came back reports.
    private static func linkSubagents(_ sources: [Source], window: Range<Date>, into builder: inout Builder) {
        let byCall = Dictionary(
            sources.enumerated().compactMap { index, source in source.startedBy.map { ($0, index) } },
            uniquingKeysWith: { first, _ in first })
        for index in builder.steps.indices where builder.steps[index].kind == .spawn {
            builder.steps[index].other = builder.spawnCalls[index].flatMap { byCall[$0] }
        }
        // A subagent reports back to whoever started it: the session's agent, or a subagent that started its own.
        for (parent, source) in sources.enumerated() {
            for call in source.log.calls where window.contains(call.at) {
                guard let child = byCall[call.id], child != parent, let done = call.done else { continue }
                var step = AgentWork.Step(agent: child, kind: .report, tool: "Report", detail: "", at: done)
                step.other = parent
                builder.steps.append(step)
            }
        }
    }

    // MARK: Building

    struct Builder {
        let layout: Places
        var placesByKey: [String: Int] = [:]
        var list: [AgentWork.Place] = []
        /// The worktrees each project place was edited and read in, by its index ("" for the project's own folder).
        var trees: [Int: (edits: Set<String>, reads: Set<String>)] = [:]
        var verbs: [Int: [String: Int]] = [:]
        var steps: [AgentWork.Step] = []
        /// The call id behind each spawn step, by the step's index.
        var spawnCalls: [Int: String] = [:]

        /// The project's root as an agent may write it: as Kelp has it, with or without `/private`, and as it really is
        /// on this Mac (a root reached through a link; a host's path isn't on this Mac and stays as written).
        let roots: [String]

        init(places: Places) {
            layout = places
            roots = Builder.variants(places.root) + (Paths.real(places.root).map(Builder.variants) ?? [])
        }

        var places: [AgentWork.Place] {
            list.enumerated().map { index, place in
                var place = place
                if let counts = verbs[index],
                    let top = counts.max(by: { $0.value < $1.value || $0.value == $1.value && $0.key > $1.key })
                {
                    place.detail = top.value > 1 ? "\(top.key) ×\(top.value)" : top.key
                }
                // Where the file is: the worktree it was edited in, else the one it was read in, when that is one
                // worktree and not the project itself ("" stands for the project's own folder).
                if let seen = trees[index] {
                    func one(_ trees: Set<String>) -> String? {
                        trees.count == 1 ? trees.first.flatMap { $0.isEmpty ? nil : $0 } : nil
                    }
                    place.worktree = seen.edits.isEmpty ? one(seen.reads) : one(seen.edits)
                }
                return place
            }
        }

        /// Adds what one call touched; returns the first place it touched.
        mutating func add(_ call: WorkLog.Call, agent: Int, steps keepSteps: Bool) -> Int? {
            let tool = call.tool, lower = tool.lowercased()
            var first: Int?
            func touch(
                _ kind: AgentWork.Kind, _ name: String, read: Bool = false, edit: Bool = false,
                added: Int = 0, removed: Int = 0, worktree: String? = nil, verb: String? = nil
            ) {
                let index = place(kind, name, agent: agent, at: call.at)
                if read { list[index].reads += 1 }
                if edit {
                    list[index].edits += 1
                    list[index].added += added
                    list[index].removed += removed
                }
                if kind == .file || kind == .folder {
                    if edit { trees[index, default: ([], [])].edits.insert(worktree ?? "") }
                    if read { trees[index, default: ([], [])].reads.insert(worktree ?? "") }
                }
                if let verb { verbs[index, default: [:]][verb, default: 0] += 1 }
                first = first ?? index
            }
            func file(_ path: String?, edit: Bool = false, search: Bool = false, added: Int = 0, removed: Int = 0) {
                guard let path, let where_ = locate(path, cwd: call.cwd) else { return }
                switch where_ {
                case .project(let name, let worktree):
                    let kind: AgentWork.Kind = search && !Self.isFile(name) ? .folder : .file
                    touch(kind, name, read: !edit, edit: edit, added: added, removed: removed, worktree: worktree)
                case .outside(let kind, let name): touch(kind, name, read: !edit, edit: edit)
                }
            }
            var kind: AgentWork.Step.Kind = .other, detail = ""
            switch lower {
            // A read or an edit that failed touched nothing: it shows as a failed step, not as a place.
            case "read", "notebookread", "view":
                if !call.failed { file(call.path) }
                (kind, detail) = (.read, shown(call.path))
            case "edit", "multiedit", "write", "notebookedit", "str_replace_based_edit_tool":
                if !call.failed { file(call.path, edit: true, added: call.added, removed: call.removed) }
                (kind, detail) = (.edit, shown(call.path))
            case "grep", "glob", "ls":
                file(call.path ?? call.cwd ?? layout.root, search: true)
                (kind, detail) = (
                    .search, [call.pattern, call.path.map(shown)].compactMap { $0 }.joined(separator: " in ")
                )
            case "bash", "shell", "shell_command", "exec_command", "local_shell", "exec":
                let command = call.command ?? ""
                for touched in ShellTouches.parse(command) {
                    switch touched {
                    case .read(let path, let search): file(path, search: search)
                    case .wrote(let path): file(path, edit: true)
                    case .site(let host, let verb): touch(.web, host, read: true, verb: verb)
                    case .host(let host, let verb): touch(.machine, host, read: true, verb: verb)
                    case .packages(let manager, let verb): touch(.packages, manager, read: true, verb: verb)
                    case .remote(let name, let verb):
                        // `git push` names no host: the project's origin's, else a place of its own.
                        let host = name.isEmpty ? layout.remote ?? "git remote" : name
                        touch(.web, host, read: true, verb: verb)
                    }
                }
                let line = command.split(separator: "\n").first.map(String.init) ?? command
                (kind, detail) = (call.failed ? .failed : .command, String(line.prefix(200)))
            case "apply_patch":
                for (path, added, removed) in Self.patchFiles(call.patch ?? "") where !call.failed {
                    file(path, edit: true, added: added, removed: removed)
                }
                (kind, detail) = (.edit, Self.patchFiles(call.patch ?? "").map { shown($0.0) }.joined(separator: ", "))
            case "webfetch":
                let host = call.url.flatMap { URL(string: $0)?.host } ?? "web"
                touch(.web, host, read: true, verb: "fetch")
                (kind, detail) = (.web, host)
            case "websearch":
                touch(.web, "Web Search", read: true, verb: "search")
                (kind, detail) = (.web, call.query ?? "")
            case "task", "agent":
                (kind, detail) = (.spawn, call.task ?? call.kind ?? "")
            case "askuserquestion", "exitplanmode":
                (kind, detail) = (.ask, call.query ?? "")
            case "todowrite", "update_plan", "subagenthandback", "toolsearch": return first
            default:
                if lower.hasPrefix("mcp__") {
                    let parts = tool.components(separatedBy: "__")
                    let server = parts.count > 1 ? parts[1] : tool, action = parts.count > 2 ? parts[2] : ""
                    touch(.tool, server, read: true, verb: action)
                    (kind, detail) = (.tool, "\(server) · \(action)")
                } else {
                    detail = call.path.map(shown) ?? call.query ?? ""
                }
            }
            if keepSteps {
                if call.failed, kind != .spawn { kind = .failed }
                var step = AgentWork.Step(agent: agent, kind: kind, tool: tool, detail: detail, at: call.at)
                step.added = call.added
                step.removed = call.removed
                if kind == .spawn { spawnCalls[steps.count] = call.id }
                steps.append(step)
            }
            return first
        }

        mutating func changedByCommand(_ change: Changed) {
            let name = Self.unfolded(change.path).name
            if let index = placesByKey[key(.file, name)], list[index].edits > 0 { return }
            let index = place(.file, name, agent: nil, at: nil)
            list[index].byCommand = true
            list[index].added = change.added
            list[index].removed = change.removed
        }

        private func key(_ kind: AgentWork.Kind, _ name: String) -> String { kind.rawValue + "\u{0}" + name }

        private mutating func place(_ kind: AgentWork.Kind, _ name: String, agent: Int?, at: Date?) -> Int {
            let k = key(kind, name)
            let index =
                placesByKey[k]
                ?? {
                    list.append(AgentWork.Place(kind: kind, name: name))
                    placesByKey[k] = list.count - 1
                    return list.count - 1
                }()
            if let agent, !list[index].agents.contains(agent) { list[index].agents.append(agent) }
            if let at {
                list[index].first = min(list[index].first ?? at, at)
                list[index].last = max(list[index].last ?? at, at)
            }
            return index
        }

        enum Where { case project(String, worktree: String?), outside(AgentWork.Kind, String) }

        /// Where a path is: in the project (from its root, a worktree under `.claude/worktrees` folded onto it), the
        /// agent's own folders, or another folder outside, shortened to two levels.
        func locate(_ raw: String, cwd: String?) -> Where? {
            guard !raw.isEmpty else { return nil }
            var path = raw
            if path == "~" || path.hasPrefix("~/") { path = layout.home + path.dropFirst() }
            if !path.hasPrefix("/") { path = ((cwd ?? layout.root) as NSString).appendingPathComponent(path) }
            path = URL(fileURLWithPath: path, isDirectory: false).standardized.path   // no disk lookup
            // The paths are compared as the agent wrote them, not resolved: a host's paths can't be resolved here.
            for root in roots {
                if path == root { return .project(".", worktree: nil) }
                if let below = Paths.relative(path, to: root) {
                    let unfolded = Self.unfolded(below)
                    return .project(unfolded.name, worktree: unfolded.worktree)
                }
            }
            let own = [layout.home + "/.claude", layout.home + "/.codex"] + Places.temporary.flatMap(Self.variants)
            if own.contains(where: { path == $0 }) || own.contains(where: { Paths.relative(path, to: $0) != nil }) {
                return .outside(.own, Self.ownName(path, home: layout.home))
            }
            if let below = Paths.relative(path, to: layout.home) {
                return .outside(.outside, "~/" + below.split(separator: "/").prefix(2).joined(separator: "/"))
            }
            return .outside(.outside, "/" + path.split(separator: "/").prefix(2).joined(separator: "/"))
        }

        private static func ownName(_ path: String, home: String) -> String {
            if path.hasPrefix(home + "/.claude") { return "~/.claude" }
            if path.hasPrefix(home + "/.codex") { return "~/.codex" }
            return "/tmp"
        }

        /// A path inside `.claude/worktrees/<name>/` (Claude Code's worktrees) is the project's own path in that
        /// worktree.
        static func unfolded(_ relative: String) -> (name: String, worktree: String?) {
            let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 3, parts[0] == ".claude", parts[1] == "worktrees" {
                return (parts.count == 3 ? "." : parts.dropFirst(3).joined(separator: "/"), String(parts[2]))
            }
            // The worktrees' own folder, looked into: the project, not a folder of it.
            if parts.count == 2, parts[0] == ".claude", parts[1] == "worktrees" { return (".", nil) }
            return (relative, nil)
        }

        /// `/tmp` and `/private/tmp` are one folder; an agent writes either.
        static func variants(_ path: String) -> [String] {
            let clean = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
            if clean.hasPrefix("/private/") { return [clean, String(clean.dropFirst("/private".count))] }
            return [clean, "/private" + clean]
        }

        static func isFile(_ name: String) -> Bool {
            let last = (name as NSString).lastPathComponent
            return last.contains(".") && !last.hasPrefix(".") && last != "."
        }

        /// The files a Codex patch touches, with its + and − lines each.
        static func patchFiles(_ patch: String) -> [(String, Int, Int)] {
            var out: [(String, Int, Int)] = []
            for line in patch.split(separator: "\n") {
                if let match = line.firstMatch(of: /^\*\*\* (?:Update|Add|Delete) File: (.+)$/) {
                    out.append((String(match.1).trimmingCharacters(in: .whitespaces), 0, 0))
                } else if !out.isEmpty, !line.hasPrefix("***") {
                    if line.hasPrefix("+") {
                        out[out.count - 1].1 += 1
                    } else if line.hasPrefix("-") {
                        out[out.count - 1].2 += 1
                    }
                }
            }
            return out
        }

        /// A path as a step shows it: from the project's root when it's inside.
        private func shown(_ path: String?) -> String {
            guard let path else { return "" }
            if case .project(let name, _) = locate(path, cwd: nil) { return name }
            return path.hasPrefix(layout.home) ? "~" + path.dropFirst(layout.home.count) : path
        }
    }
}
