import Foundation
import Core
import GitKit

/// What a project's own files offer to run (`run.detect`, `run.start`): package.json scripts, Makefile and justfile
/// targets, compose services, Python apps, Procfile processes, cargo / go / swift / gradle / maven / mix. One shell script
/// prints the files that name commands and the programs on PATH; it runs in the workspace's folder, here or on a remote
/// project's host (one ssh call), so both are read the same way. Only these names, in the folder, its subfolders and
/// apps/* packages/* services/*: no walk over the tree.
enum Runnables {
    /// Read, up to 64 KB each.
    static let files = ["package.json", "deno.json", "deno.jsonc", "Makefile", "makefile", "GNUmakefile", "justfile", "Justfile",
                        "compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml", "Dockerfile", "pyproject.toml", "manage.py",
                        "requirements.txt", "app/main.py", "main.py", "app.py", "Procfile", "Procfile.dev", "Cargo.toml", "go.mod", "Package.swift",
                        "build.gradle", "build.gradle.kts", "pom.xml", "mix.exs"]
    /// Only whether they're there.
    static let marks = ["node_modules", ".venv", "uv.lock", "poetry.lock", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", "main.go",
                        "bin/dev", "gradlew", "artisan", "deps"]
    static let tools = ["npm", "pnpm", "yarn", "bun", "deno", "make", "just", "docker", "uv", "poetry", "python3", "cargo", "go", "swift",
                        "gradle", "mvn", "mix", "php"]
    /// The likeliest dev server first: what ⌘R guesses when nothing was run in the project yet.
    static let runNames = ["dev", "start", "serve", "runserver", "uvicorn", "flask", "phx.server", "bin/dev", "web", "server", "bootRun",
                           "run", "up", "main.py", "app.py"]

    /// Files as \036path\037text (a mark has no text), Go's cmd/* folders as marks, then \035 and the programs found.
    static var script: String {
        let q = { (names: [String]) in names.map(RemoteHost.quote).joined(separator: " ") }
        return #"for d in . * apps/* packages/* services/*; do [ -d "$d" ] || continue; "#
            + #"case "${d##*/}" in node_modules|vendor|venv|dist|build|target|out|coverage) continue;; esac; "#
            + "for f in \(q(files)); do [ -f \"$d/$f\" ] && { printf '\\036%s\\037' \"$d/$f\"; head -c 65536 \"$d/$f\"; }; done; "
            + "for f in \(q(marks)); do [ -e \"$d/$f\" ] && printf '\\036%s\\037' \"$d/$f\"; done; "
            + #"for c in "$d"/cmd/*/; do [ -d "$c" ] && printf '\036%s\037' "${c%/}"; done; done; printf '\035'; "#
            + "for t in \(q(tools)); do command -v \"$t\" >/dev/null 2>&1 && echo \"$t\"; done; exit 0"
    }

    struct Found {
        /// Path in the workspace → its text ("" for a mark).
        var files: [String: String] = [:]
        /// nil: the list didn't come (the script was cut short), so nothing is said to be missing.
        var tools: Set<String>?
        func text(_ folder: String, _ name: String) -> String? { files[join(folder, name)] }
        func has(_ folder: String, _ name: String) -> Bool { files[join(folder, name)] != nil }
    }

    static func join(_ folder: String, _ name: String) -> String { folder.isEmpty ? name : folder + "/" + name }

    /// What the script printed. Anything before the first file is the host shell's greeting.
    /// Limit: a file holding \036 or \037 itself is cut there.
    static func parse(_ out: String) -> Found {
        var f = Found()
        let halves = out.split(separator: "\u{1D}", maxSplits: 1, omittingEmptySubsequences: false)
        for entry in (halves.first.map(String.init) ?? "").components(separatedBy: "\u{1E}").dropFirst() {
            let kv = entry.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard let path = kv.first, !path.isEmpty else { continue }
            f.files[path.hasPrefix("./") ? String(path.dropFirst(2)) : String(path)] = kv.count > 1 ? String(kv[1]) : ""
        }
        if halves.count > 1 { f.tools = Set(halves[1].split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }) }
        return f
    }

    /// The folder a listed path is in: names with a "/" of their own (app/main.py, bin/dev) are matched first.
    static func folder(of path: String) -> String {
        for n in (files + marks).sorted(by: { $0.count > $1.count }) where path == n || path.hasSuffix("/" + n) {
            return path == n ? "" : String(path.dropLast(n.count + 1))
        }
        guard let r = path.range(of: "cmd/", options: .backwards) else { return "" }
        return String(path[..<r.lowerBound].dropLast(path[..<r.lowerBound].hasSuffix("/") ? 1 : 0))
    }

    /// Every folder's, its own folder first; a command found twice in one folder (a Makefile's `dev: npm run dev`) once.
    static func options(_ f: Found) -> [RunOption] {
        let folders = Set(f.files.keys.map(folder(of:))).sorted { ($0.isEmpty ? 0 : 1, $0) < ($1.isEmpty ? 0 : 1, $1) }
        let finders: [(Found, String) -> [RunOption]] = [node, make, compose, python, compiled, procfile]
        let all = folders.flatMap { d in finders.flatMap { $0(f, d) } }
        var seen = Set<String>()
        return Array(all.filter { seen.insert($0.folder + "\u{0}" + $0.command).inserted }.prefix(60))
    }

    /// The dev server ⌘R would pick: the best-ranked runnable one, its own folder before subfolders.
    static func guess(_ options: [RunOption]) -> String? {
        let order = { (o: (offset: Int, element: RunOption)) in (rank(o.element.name), o.element.folder.isEmpty ? 0 : 1, o.offset) }
        return options.enumerated().filter { $0.element.kind == "run" && $0.element.missing == nil }.min { order($0) < order($1) }?.element.id
    }

    static func rank(_ name: String) -> Int { runNames.firstIndex(of: name) ?? runNames.count }

    static func kind(_ name: String) -> String {
        let n = name.lowercased()
        if runNames.contains(name) { return "run" }
        if n.hasPrefix("test") || n == "spec" || n == "pytest" { return "test" }
        if n.hasPrefix("build") || n == "compile" { return "build" }
        if ["lint", "format", "fmt", "typecheck"].contains(where: n.hasPrefix) { return "lint" }
        return "other"
    }

    static func opt(_ f: Found, _ d: String, _ source: String, _ name: String, _ command: String, kind: String? = nil, detail: String? = nil,
                    tool: String? = nil) -> RunOption {
        RunOption(id: [d, source, name].joined(separator: "|"), name: name, command: command, folder: d, source: source, kind: kind ?? Self.kind(name),
                  detail: detail == command ? nil : detail, missing: tool.flatMap { t in f.tools.map { $0.contains(t) ? nil : t } ?? nil })
    }

    static func byRank(_ a: String, _ b: String) -> Bool { (rank(a), a) < (rank(b), b) }

    // MARK: the files

    /// package.json's scripts (its pre/post hooks left out) through its package manager, and deno.json's tasks. No
    /// node_modules here or above: installing them is an entry of its own.
    static func node(_ f: Found, _ d: String) -> [RunOption] {
        var out: [RunOption] = []
        if let json = f.text(d, "package.json").flatMap(object) {
            let pm = manager(f, d, json["packageManager"] as? String)
            let scripts = (json["scripts"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            let hooks = scripts.keys.filter { k in ["pre", "post"].contains { k.hasPrefix($0) && scripts[String(k.dropFirst($0.count))] != nil } }
            out += scripts.keys.filter { !hooks.contains($0) }.sorted(by: byRank)
                .map { opt(f, d, "package.json", $0, "\(pm) run \($0)", detail: scripts[$0], tool: pm) }
            if !f.has(d, "node_modules"), !f.has("", "node_modules") {
                out.append(opt(f, d, "package.json", "install", "\(pm) install", kind: "install", tool: pm))
            }
        }
        for file in ["deno.json", "deno.jsonc"] {
            guard let tasks = f.text(d, file).flatMap(object)?["tasks"] as? [String: Any] else { continue }
            out += tasks.keys.sorted(by: byRank).map { opt(f, d, file, $0, "deno task \($0)", detail: tasks[$0] as? String, tool: "deno") }
        }
        return out
    }

    static func object(_ text: String) -> [String: Any]? {
        Log.session.attempt("reading a project's JSON") { try JSONSerialization.jsonObject(with: Data(text.utf8), options: .json5Allowed) } as? [String: Any]
    }

    /// package.json's packageManager, else the lock file here or in the workspace's folder (a monorepo's), else npm.
    static func manager(_ f: Found, _ d: String, _ field: String?) -> String {
        if let name = field?.split(separator: "@").first.map(String.init), ["npm", "pnpm", "yarn", "bun"].contains(name) { return name }
        let locks = [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lock", "bun"), ("bun.lockb", "bun")]
        return [d, ""].lazy.compactMap { dir in locks.first { f.has(dir, $0.0) }?.1 }.first ?? "npm"
    }

    // swiftlint:disable:next force_try
    static let makeTarget = try! NSRegularExpression(pattern: #"^([A-Za-z0-9][A-Za-z0-9_./-]*)\s*::?(?!=)(?:[^#\n]*##\s*(.*))?"#)
    // swiftlint:disable:next force_try
    static let justRecipe = try! NSRegularExpression(pattern: #"^@?([A-Za-z0-9][A-Za-z0-9_-]*)(?:\s+[^:=\n]*)?:(?!=)"#)

    /// A Makefile's targets ("## text" after one is its description) and a justfile's recipes.
    static func make(_ f: Found, _ d: String) -> [RunOption] {
        var out: [RunOption] = []
        if let file = ["Makefile", "makefile", "GNUmakefile"].first(where: { f.has(d, $0) }), let text = f.text(d, file) {
            // `help` only prints the list this menu already is.
            for (name, about) in matches(makeTarget, text) where name != "help" && !out.contains(where: { $0.name == name }) {
                out.append(opt(f, d, file, name, "make \(name)", detail: about, tool: "make"))
            }
        }
        if let file = ["justfile", "Justfile"].first(where: { f.has(d, $0) }), let text = f.text(d, file) {
            let words: Set = ["set", "export", "alias", "import", "mod"]
            for (name, _) in matches(justRecipe, text) where !words.contains(name) && !out.contains(where: { $0.name == name }) {
                out.append(opt(f, d, file, name, "just \(name)", tool: "just"))
            }
        }
        return out.prefix(30).sorted { byRank($0.name, $1.name) }
    }

    /// Each line's first group and, when it matched, its second.
    static func matches(_ re: NSRegularExpression, _ text: String) -> [(String, String?)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let s = String(line)
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
            let about = m.numberOfRanges > 2 ? Range(m.range(at: 2), in: s).map { String(s[$0]).trimmingCharacters(in: .whitespaces) } : nil
            return (String(s[r]), about?.isEmpty == false ? about : nil)
        }
    }

    /// The whole compose file, then each service (its first published port beside it); a lone Dockerfile built and run.
    static func compose(_ f: Found, _ d: String) -> [RunOption] {
        guard let file = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"].first(where: { f.has(d, $0) }),
              let text = f.text(d, file) else { return dockerfile(f, d) }
        let services = Self.services(text)
        return [opt(f, d, file, "up", "docker compose up", kind: "run", detail: services.map(\.name).joined(separator: ", "), tool: "docker")]
            + services.map { opt(f, d, file, $0.name, "docker compose up \($0.name)", kind: "other", detail: $0.port.map { ":\($0)" }, tool: "docker") }
    }

    // swiftlint:disable:next force_try
    static let portLine = try! NSRegularExpression(pattern: #"^\s*-\s*["']?(?:[\d.]+:)?(\d+)(?:-\d+)?:\d+"#)

    /// The keys under `services:` (at the first indent found there) and the first host port each publishes.
    static func services(_ text: String) -> [(name: String, port: String?)] {
        var out: [(name: String, port: String?)] = [], inside = false, indent: Int?
        for line in text.split(whereSeparator: \.isNewline).map(String.init) where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            let lead = line.prefix { $0 == " " }.count
            if lead == 0 { inside = line.hasPrefix("services:"); continue }
            guard inside else { continue }
            if indent == nil { indent = lead }
            if lead == indent, line.hasSuffix(":") { out.append((line.trimmingCharacters(in: .whitespaces).dropLast().description, nil)); continue }
            if let last = out.indices.last, out[last].port == nil, let (p, _) = matches(portLine, line).first { out[last].port = p }
        }
        return out
    }

    static func dockerfile(_ f: Found, _ d: String) -> [RunOption] {
        guard let text = f.text(d, "Dockerfile") else { return [] }
        let tag = (d.isEmpty ? "app" : (d as NSString).lastPathComponent).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let port = text.split(whereSeparator: \.isNewline).lazy.compactMap { l -> String? in
            let w = l.split(separator: " ")
            return w.count > 1 && w[0].uppercased() == "EXPOSE" ? w[1].split(separator: "/").first.map(String.init) : nil
        }.first
        let publish = port.map { " -p \($0):\($0)" } ?? ""
        return [opt(f, d, "Dockerfile", "docker", "docker build -t \(tag) . && docker run --rm -it\(publish) \(tag)", kind: "run", tool: "docker")]
    }

    /// Django's runserver, a FastAPI or Flask app, pyproject's scripts and pytest — through uv or poetry when the project
    /// uses them, else its .venv, else the PATH's python3. requirements.txt with no .venv: making one is an entry of its own.
    static func python(_ f: Found, _ d: String) -> [RunOption] {
        let py = f.text(d, "pyproject.toml")
        guard py != nil || ["manage.py", "requirements.txt", "main.py", "app.py", "app/main.py"].contains(where: { f.has(d, $0) }) else { return [] }
        let (prefix, tool): (String, String?) = f.has(d, "uv.lock") ? ("uv run ", "uv") : f.has(d, "poetry.lock") ? ("poetry run ", "poetry")
            : f.has(d, ".venv") ? (".venv/bin/", nil) : ("", "python3")
        let source = py != nil ? "pyproject.toml" : f.has(d, "requirements.txt") ? "requirements.txt" : "python"
        func run(_ program: String, _ args: String = "") -> String {
            prefix + (program == "python" && prefix.isEmpty ? "python3" : program) + (args.isEmpty ? "" : " " + args)
        }
        var out: [RunOption] = []
        if f.has(d, "manage.py") {
            out += [opt(f, d, "manage.py", "runserver", run("python", "manage.py runserver"), tool: tool),
                    opt(f, d, "manage.py", "test", run("python", "manage.py test"), tool: tool)]
        }
        for (file, module) in [("app/main.py", "app.main"), ("main.py", "main"), ("app.py", "app")] where out.isEmpty {
            guard let text = f.text(d, file) else { continue }
            if let v = matches(fastAPI, text).first?.0 {
                out.append(opt(f, d, file, "uvicorn", run("uvicorn", "\(module):\(v) --reload"), tool: tool))
            } else if !matches(flask, text).isEmpty {
                out.append(opt(f, d, file, "flask", run("flask", "--app \(module) run --debug"), tool: tool))
            } else if !file.contains("/") { out.append(opt(f, d, file, file, run("python", file), tool: tool)) }
        }
        if let py {
            for section in ["[project.scripts]", "[tool.poetry.scripts]"] {
                guard let start = py.range(of: section) else { continue }
                let body = py[start.upperBound...].prefix { $0 != "[" }
                for line in body.split(whereSeparator: \.isNewline) {
                    let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count == 2, !kv[0].isEmpty else { continue }
                    let target = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    out.append(opt(f, d, "pyproject.toml", kv[0], run(kv[0]), detail: target, tool: tool))
                }
            }
            if py.contains("pytest") { out.append(opt(f, d, "pyproject.toml", "pytest", run("pytest"), tool: tool)) }
        }
        if f.has(d, "requirements.txt"), prefix.isEmpty {
            out.append(opt(f, d, source, "install", "python3 -m venv .venv && .venv/bin/pip install -r requirements.txt", kind: "install", tool: "python3"))
        }
        return out
    }

    // swiftlint:disable:next force_try
    static let fastAPI = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*FastAPI\("#)
    // swiftlint:disable:next force_try
    static let flask = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*Flask\("#)

    /// cargo, go (each cmd/* program), swift, gradle / maven (Spring Boot's bootRun), mix (Phoenix), artisan, bin/dev.
    static func compiled(_ f: Found, _ d: String) -> [RunOption] {
        var out: [RunOption] = []
        if f.has(d, "Cargo.toml") {
            out += ["run", "test", "build"].map { opt(f, d, "Cargo.toml", $0, "cargo \($0)", tool: "cargo") }
        }
        if f.has(d, "go.mod") {
            if f.has(d, "main.go") { out.append(opt(f, d, "go.mod", "run", "go run .", tool: "go")) }
            let cmds = f.files.keys.filter { folder(of: $0) == d && $0.contains("cmd/") && f.files[$0] == "" }.sorted()
            out += cmds.map { p in let n = (p as NSString).lastPathComponent; return opt(f, d, "go.mod", n, "go run ./cmd/\(n)", kind: "run", tool: "go") }
            out += [opt(f, d, "go.mod", "test", "go test ./...", tool: "go"), opt(f, d, "go.mod", "build", "go build ./...", tool: "go")]
        }
        if f.has(d, "Package.swift") { out += ["run", "test", "build"].map { opt(f, d, "Package.swift", $0, "swift \($0)", tool: "swift") } }
        if let file = ["build.gradle.kts", "build.gradle"].first(where: { f.has(d, $0) }), let text = f.text(d, file) {
            let (gradle, tool) = f.has(d, "gradlew") ? ("./gradlew", nil as String?) : ("gradle", "gradle")
            let task = text.contains("springframework.boot") ? "bootRun" : text.contains("application") ? "run" : nil
            out += (task.map { [$0] } ?? []).map { opt(f, d, file, $0, "\(gradle) \($0)", tool: tool) }
            out.append(opt(f, d, file, "test", "\(gradle) test", tool: tool))
        }
        if let pom = f.text(d, "pom.xml") {
            if pom.contains("spring-boot") { out.append(opt(f, d, "pom.xml", "run", "mvn spring-boot:run", tool: "mvn")) }
            out.append(opt(f, d, "pom.xml", "test", "mvn test", tool: "mvn"))
        }
        if let mix = f.text(d, "mix.exs") {
            if mix.contains(":phoenix") { out.append(opt(f, d, "mix.exs", "phx.server", "mix phx.server", tool: "mix")) }
            out.append(opt(f, d, "mix.exs", "test", "mix test", tool: "mix"))
            if !f.has(d, "deps") { out.append(opt(f, d, "mix.exs", "install", "mix deps.get", kind: "install", tool: "mix")) }
        }
        if f.has(d, "artisan") { out.append(opt(f, d, "artisan", "serve", "php artisan serve", kind: "run", tool: "php")) }
        if f.has(d, "bin/dev") { out.append(opt(f, d, "bin/dev", "bin/dev", "bin/dev")) }
        return out
    }

    /// Each process of a Procfile (Procfile.dev first: it's the one for running locally).
    static func procfile(_ f: Found, _ d: String) -> [RunOption] {
        ["Procfile.dev", "Procfile"].flatMap { file in
            (f.text(d, file) ?? "").split(whereSeparator: \.isNewline).compactMap { line -> RunOption? in
                let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2, !kv[0].isEmpty, !kv[0].hasPrefix("#"), !kv[1].isEmpty else { return nil }
                return opt(f, d, file, kv[0], kv[1])
            }
        }
    }
}

extension Workspaces {
    /// What the workspace's files offer to run, read where they are: on a remote project's host, through its shell (its
    /// PATH: nvm, pyenv), over the shared connection.
    func runOptions(_ w: Worktree) throws -> [RunOption] {
        let out: String
        if let remote = remotes.of(w.path) {
            out = try Git.run(remote.sshArgs(tty: false) + [remote.command(["sh", "-c", Runnables.script])], cwd: NSHomeDirectory(), executable: remotes.ssh)
        } else {
            out = try Git.run(["-c", Runnables.script], cwd: w.path, executable: "/bin/sh", env: ["PATH": Sessions.childPath])
        }
        return Runnables.options(Runnables.parse(out))
    }
}

extension RunDetect: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result {
        let options = try workspaces.runOptions(try workspaces.store.worktree(named: worktreeId))
        return Result(options: options, guess: Runnables.guess(options))
    }
}

extension RunStart: Handled {
    /// The option as the files say now, not a command the caller sends: what runs is what the list showed. A remote
    /// project's run goes in tmux on the host, so a dropped connection leaves the server running.
    func handle(_ workspaces: Workspaces) throws -> Session {
        let w = try workspaces.store.worktree(named: worktreeId)
        guard let o = try workspaces.runOptions(w).first(where: { $0.id == id }) else {
            throw RPCError.invalidParams("“\(id.split(separator: "|").last ?? "")” is no longer in the project's files.")
        }
        var l = Sessions.Launch()
        l.title = o.folder.isEmpty ? o.name : "\((o.folder as NSString).lastPathComponent) › \(o.name)"
        l.openURLs = true
        l.onHostInTmux = true
        let command = o.folder.isEmpty ? o.command : "cd \(RemoteHost.quote(o.folder)) && \(o.command)"
        return try workspaces.sessions.spawn(cwd: w.path, manifest: .custom(command), worktreeId: w.id, l)
    }
}

extension RemoteHost {
    /// A server on the host at `url` (its localhost) reached from this Mac over the shared connection: the same port here
    /// when it's free, else the next free one of ten → the URL to open here, and the forwarding (`cancel` takes it).
    /// Nothing forwarded (no shared connection, every port taken): the URL as it was, and nil.
    func forward(_ url: String) -> (url: String, spec: String?) {
        guard var u = URLComponents(string: url), let port = u.port else { return (url, nil) }
        let target = u.host == "127.0.0.1" ? "127.0.0.1" : "localhost"
        for here in port..<port + 10 {
            let spec = "\(here):\(target):\(port)"
            do { try control("forward", spec) } catch { continue }   // taken here: the next one
            u.host = "localhost"
            u.port = here
            return (u.string ?? url, spec)
        }
        return (url, nil)
    }
    func cancel(_ spec: String) { Log.session.attempt("ending the forwarding \(spec)") { try control("cancel", spec) } }

    /// `ssh -O`: asks the shared connection's master, which adds or drops a forwarding without a new login.
    private func control(_ op: String, _ spec: String) throws {
        _ = try Git.run(["-o", "ControlPath=\(controlDir)/%C", "-O", op, "-L", spec, "--", host], cwd: NSHomeDirectory(), executable: ssh)
    }
}
