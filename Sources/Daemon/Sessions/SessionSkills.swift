import AgentData
import Core
import Foundation
import GRDB

/// Kelp's skills for a Claude Code session: each a plugin folder the app writes into `agent-skills`, passed one by one
/// (`--plugin-dir`), with a sentence of context. By default the browser skill goes only to a project with a web app,
/// decided when the chat starts (and again at a restart). Its one line costs every chat ~95 tokens, and an agent with
/// no page to look at is better off without the tool.
extension SessionSetup {
    static let kelpIntro =
        "This Claude Code session runs inside Kelp, a macOS IDE; the user sees Kelp's window, not Claude Code's UI."

    /// The flags for the skills on disk, and the hover card's line about the browser skill (nil without it).
    func skillArgs(flag: String, contextFlag: String?, worktreeId: String?, cwd: String, profile: String? = nil) -> (
        argv: [String], browser: String?
    ) {
        let dir = Paths.agentSkills(in: root)
        let (on, browser) = chosenSkills(worktreeId: worktreeId, cwd: cwd, claude: true, profile: profile)
        var argv = on.flatMap { [flag, $0.path] }
        let guide = browser.flatMap {
            $0.on || !$0.hint ? nil : dir.appendingPathComponent("kelp-browser/skills/kelp-browser/SKILL.md").path
        }
        if let contextFlag, let text = Self.kelpContext(on.map(\.lastPathComponent), browserGuide: guide) {
            argv += [contextFlag, text]
        }
        return (argv, browser?.line)
    }

    /// Kelp's skills on disk that a chat starting in `cwd` gets (each a plugin folder), and the choice about the
    /// browser skill. `claude` means a Claude Code chat (of account `profile`), which may have pages of its own
    /// (`artifactsSkill`).
    func chosenSkills(worktreeId: String?, cwd: String, claude: Bool = false, profile: String? = nil) -> (
        on: [URL], browser: BrowserSkill?
    ) {
        let dir = Paths.agentSkills(in: root)
        let all = WebApp.folders(in: dir).map(\.lastPathComponent).sorted()
            .map { dir.appendingPathComponent($0) }   // this home's own spelling (not /private/tmp for /tmp): a restart finds them by it
        let hasBrowser = all.contains { $0.lastPathComponent == "kelp-browser" }
        let browser = hasBrowser ? browserSkill(worktreeId: worktreeId, cwd: cwd) : nil
        let machines =
            FileManager.default.enumerator(
                at: root.appendingPathComponent("vms"), includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])?.nextObject() != nil
        let hasDatabases = all.contains { $0.lastPathComponent == "kelp-db" } && hasDatabases(worktreeId: worktreeId)
        let artifacts =
            all.contains { $0.lastPathComponent == "kelp-artifacts" }
            && artifactsSkill(claude: claude, profile: profile)
        let off = addonsOff(worktreeId: worktreeId).off   // the project's own switches (`addons.set`)
        let on = all.filter {
            !off.contains("kelp:\($0.lastPathComponent)")
                && ($0.lastPathComponent != "kelp-browser" || browser?.on == true)
                && ($0.lastPathComponent != "kelp-vm" || machines)
                && ($0.lastPathComponent != "kelp-db" || hasDatabases)
                && ($0.lastPathComponent != "kelp-artifacts" || artifacts)
        }
        return (on, browser)
    }

    /// Whether a chat gets Kelp's pages skill (`agents.skills.artifacts`): every agent, none, or (the default) those
    /// with no artifacts of their own. Kelp's guide sends a Claude Code that publishes its own pages there anyway, so
    /// the skill would cost every chat its line and every page a detour.
    func artifactsSkill(claude: Bool, profile: String?) -> Bool {
        switch settings[SettingKeys.skillArtifacts] {
        case "off": false
        case "all": true
        default: !claude || !claudePublishesPages(profile: profile)
        }
    }

    /// Whether the account's last Claude Code chat loaded claude.ai's artifacts, as its transcript says. The newest
    /// chat whose transcript notes what it loaded decides (a chat that just started has no such note yet).
    /// Limit: the first chat on a Mac or in a profile has nothing to go by, so it gets Kelp's pages.
    func claudePublishesPages(profile: String?) -> Bool {
        let recent =
            Log.store.attempt("the last Claude Code chats") {
                try store.db.read {
                    try Session.filter(Column("agent") == Session.claudeAgent && Column("profile") == profile)
                        .order(Column("createdAt").desc).limit(5).fetchAll($0)
                }
            } ?? []
        for chat in recent {
            guard let url = agentUsage.conversations.transcript(of: chat),
                let loaded = ClaudeLoaded.read(transcript: url), !loaded.tools.isEmpty || !loaded.notes.isEmpty
            else { continue }
            return loaded.publishesPages
        }
        return false
    }

    /// One sentence naming the skills that are on. Without it, "add a panel" reads as a request for the agent's own UI.
    /// `browserGuide` is set when the browser skill is off here, so the agent hears where its guide is (a few words,
    /// not the skill's line).
    static func kelpContext(_ on: [String], browserGuide: String?) -> String? {
        let kelp = ["kelp-extensions", "kelp-settings"].filter(on.contains)
        guard !kelp.isEmpty || browserGuide != nil else { return nil }
        var text = kelpIntro
        if !kelp.isEmpty {
            text +=
                " Any request to add or change a panel, tab, list, command, setting or theme means Kelp: follow the "
                + kelp.joined(separator: " / ")
                + " skill. Never create Claude Code mods, plugins, hooks or MCP servers for such requests — Kelp doesn't load them."
        }
        if let browserGuide {
            text += " To see or try a web page, read \(browserGuide) first: Kelp opens it in a tab beside you."
        }
        return text
    }

    /// Whether the argv names this home's skills (a restart's argv comes from the record).
    static func hasSkills(_ argv: [String], root: URL) -> Bool {
        let dir = Paths.agentSkills(in: root).path
        return argv.contains { Paths.inside($0, dir) }
    }

    /// The argv without this home's skill folders and Kelp's sentence, for choosing them again.
    static func withoutSkills(_ argv: [String], root: URL, flag: String, contextFlag: String?) -> [String] {
        let dir = Paths.agentSkills(in: root).path
        var out: [String] = [], index = 0
        while index < argv.count {
            let next = index + 1 < argv.count ? argv[index + 1] : nil
            if let next,
                (argv[index] == flag && Paths.inside(next, dir))
                    || (argv[index] == contextFlag && next.hasPrefix(kelpIntro))
            {
                index += 2
                continue
            }
            out.append(argv[index])
            index += 1
        }
        return out
    }

    /// UI state: an agent here ran `kelp browser` once, so this project has pages to look at from now on.
    static func browserUsedKey(_ repo: String) -> String { "browser.used.\(repo)" }

    /// Whether the chat's project has a database Kelp knows of, as `kelp db list` would list it: found in its folder or,
    /// on a branch, in the project's main folder (an untracked SQLite file stays there), or added by hand. A remote
    /// project's files are read on its host only when asked for (`Databases.onHost`), so a remote project gets the
    /// skill, which says when there are none.
    func hasDatabases(worktreeId: String?) -> Bool {
        guard let id = worktreeId,
            let worktree = Log.store.attempt("the workspace \(id)", { try store.worktree(id) }) ?? nil
        else { return false }
        if remotes.of(worktree.path) != nil { return true }
        let project =
            Log.store.attempt("the project \(worktree.repoId)") { try store.repo(worktree.repoId)?.path } ?? nil
        let folders = [worktree.path] + [project].compactMap { $0 }.filter { $0 != worktree.path }
        if folders.contains(where: { !DatabaseFind.find(in: $0).isEmpty }) { return true }
        let byHand = Log.store.attempt("the project's databases") {
            try store.db.read { try SavedDatabase.filter(Column("repoId") == worktree.repoId).fetchCount($0) }
        }
        return (byHand ?? 0) > 0
    }

    func browserSkill(worktreeId: String?, cwd: String) -> BrowserSkill {
        let repo = worktreeId.flatMap { id in Log.store.attempt("the workspace \(id)") { try store.worktree(id) } ?? nil
        }?.repoId
        let choice = repo.flatMap { repoId in state(BrowserSkill.choiceKey(repoId))?.string }.flatMap(
            BrowserSkill.Choice.init(rawValue:))
        if let choice {
            return BrowserSkill(on: choice == .on, .project, choice: choice, hint: choice == .off)
        }
        switch Self.browserSetting(settings[SettingKeys.skillBrowser.key]) {
        case "on": return BrowserSkill(on: true, .always)
        case "off": return BrowserSkill(on: false, .never)
        default: break
        }
        if let repo, state(Self.browserUsedKey(repo)) != nil { return BrowserSkill(on: true, .used) }
        if let repo, localPageOpen(repo: repo) { return BrowserSkill(on: true, .localPage) }
        if let found = WebApp.found(in: URL(fileURLWithPath: cwd)) { return BrowserSkill(framework: found) }
        return BrowserSkill(on: false, .noWebApp, hint: true)
    }

    /// Reads the browser setting as "auto", "on" or "off". The on/off switch it used to be still counts as on or off.
    static func browserSetting(_ value: JSONValue?) -> String {
        if case .bool(let on)? = value { return on ? "on" : "off" }
        return value?.string ?? SettingKeys.skillBrowser.fallback
    }

    private func state(_ key: String) -> JSONValue? {
        Log.store.attempt("UI state \(key)") { try store.uiState(prefix: key)[key] } ?? nil
    }

    /// Whether a tab shows a page this Mac serves (a dev server), in any of the project's workspaces.
    private func localPageOpen(repo: String) -> Bool {
        let worktrees = Log.store.attempt("the workspaces of \(repo)") { try store.worktrees(repo: repo) } ?? []
        return worktrees.contains { worktree in
            state("layout/\(worktree.id)").map { Self.strings($0).contains(where: Self.isLocalPage) } ?? false
        }
    }

    static func isLocalPage(_ url: String) -> Bool {
        url.wholeMatch(of: /https?:\/\/(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|[^\/:]+\.local)([:\/].*)?/) != nil
    }

    static func strings(_ value: JSONValue) -> [String] {
        switch value {
        case .string(let text): [text]
        case .array(let items): items.flatMap(strings)
        case .object(let fields): fields.values.flatMap(strings)
        default: []
        }
    }
}

/// What in a folder says it's a web app, read from a few files (in it, and in the folders right inside it, like `web/`).
enum WebApp {
    static func found(in dir: URL) -> String? {
        let fm = FileManager.default
        let subs = folders(in: dir).filter {
            !["node_modules", "vendor", "venv", "dist", "build", "target", "out"].contains($0.lastPathComponent)
        }
        .sorted { $0.path < $1.path }
        for folder in [dir] + subs {
            if let why = node(folder) ?? python(folder) {
                return folder == dir ? why : why + " (\(folder.lastPathComponent))"
            }
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("index.html").path) { return "index.html" }
        for name in ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"] {
            if let contents = text(dir, name), contents.contains(/(?m)^\s+ports:/) { return "ports in \(name)" }
        }
        return nil
    }

    /// Dev-server packages by the name people know them by.
    static let frameworks: [(String, String)] = [
        ("next", "Next.js"), ("nuxt", "Nuxt"), ("astro", "Astro"), ("@sveltejs/kit", "SvelteKit"),
        ("@remix-run/dev", "Remix"),
        ("gatsby", "Gatsby"), ("@angular/core", "Angular"), ("vite", "Vite"), ("react-scripts", "Create React App"),
        ("webpack-dev-server", "webpack"), ("parcel", "Parcel"), ("express", "Express"), ("fastify", "Fastify")
    ]

    static func node(_ folder: URL) -> String? {
        guard let contents = text(folder, "package.json"),
            let manifest = (try? JSONSerialization.jsonObject(with: Data(contents.utf8))) as? [String: Any]
        else { return nil }
        let scripts = manifest["scripts"] as? [String: Any] ?? [:]
        guard !Set(scripts.keys).isDisjoint(with: ["dev", "start", "serve", "preview"]) else { return nil }
        let deps = Set(["dependencies", "devDependencies"].flatMap { (manifest[$0] as? [String: Any] ?? [:]).keys })
        return frameworks.first { deps.contains($0.0) }.map { "\($0.1) in package.json" }
    }

    static func python(_ folder: URL) -> String? {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("manage.py").path) {
            return "Django (manage.py)"
        }
        let names = [
            ("django", "Django"), ("fastapi", "FastAPI"), ("flask", "Flask"), ("gradio", "Gradio"),
            ("streamlit", "Streamlit")
        ]
        for file in ["requirements.txt", "pyproject.toml"] {
            guard let contents = text(folder, file)?.lowercased() else { continue }
            let lines = contents.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            if let hit = names.first(where: { known in lines.contains { Self.names(known.0, $0) } }) {
                return "\(hit.1) in \(file)"
            }
        }
        return nil
    }

    /// A requirements line (`flask>=3`) or a pyproject one (`"flask>=3",`) that asks for `package`.
    static func names(_ package: String, _ line: String) -> Bool {
        let rest = line.drop { $0 == "\"" || $0 == "'" }
        guard rest.hasPrefix(package) else { return false }
        let next = rest.dropFirst(package.count).first
        return next.map { !($0.isLetter || $0.isNumber || $0 == "_") } ?? true
    }

    /// A small text file, or nil (a big one isn't a manifest).
    static func text(_ folder: URL, _ name: String) -> String? {
        guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path),
            data.count < 1_000_000
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The folders right inside `dir`, none when it isn't there.
    static func folders(in dir: URL) -> [URL] {
        let items =
            FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])?.allObjects ?? []
        return items.compactMap { $0 as? URL }.filter(\.hasDirectoryPath)
    }
}

extension SkillsBrowser: Handled {
    static let agents = AgentAccess.reads
    func handle(_ setup: SessionSetup) throws -> BrowserSkill {
        setup.browserSkill(worktreeId: worktreeId, cwd: try setup.store.worktree(named: worktreeId).path)
    }
}

extension UIStore {
    /// Records that an agent drove a page from this workspace, so its project has pages to look at
    /// (`SessionSetup.browserUsedKey`).
    func browserUsed(in worktreeId: String?) {
        guard let worktreeId else { return }
        Log.store.attempt("noting the browser was used") {
            guard let repo = try store.worktree(worktreeId)?.repoId else { return }
            let key = SessionSetup.browserUsedKey(repo)
            if try store.uiState(prefix: key)[key] == nil { try store.setUIState(key, .bool(true)) }
        }
    }
}

extension Methods {
    static let skillMethods: [any Answered.Type] = [SkillsBrowser.self]
}
