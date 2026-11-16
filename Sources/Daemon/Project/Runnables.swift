import Core
import Foundation
import GitKit

/// What a project's own files offer to run (`run.detect`, `run.start`): package.json scripts, Makefile and justfile
/// targets, compose services, Python apps, Procfile processes, cargo / go / swift / gradle / maven / mix, VS Code and Zed
/// tasks. One shell script prints the files that name commands and the programs on PATH; it runs in the workspace's
/// folder, here or on a remote project's host (one ssh call), so both are read the same way. Only these names, in the
/// folder, its subfolders and apps/* packages/* services/*: no walk over the tree.
enum Runnables {
    /// Read, up to 64 KB each.
    static let files = [
        "package.json", "deno.json", "deno.jsonc", "Makefile", "makefile", "GNUmakefile", "justfile", "Justfile",
        "compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml", "Dockerfile", "pyproject.toml",
        "manage.py",
        "requirements.txt", "app/main.py", "main.py", "app.py", "Procfile", "Procfile.dev", "Cargo.toml", "go.mod",
        "Package.swift",
        "build.gradle", "build.gradle.kts", "pom.xml", "mix.exs", ".vscode/tasks.json", ".zed/tasks.json"
    ]
    /// Only whether they're there.
    static let marks = [
        "node_modules", ".venv", "uv.lock", "poetry.lock", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb",
        "main.go",
        "bin/dev", "gradlew", "artisan", "deps"
    ]
    static let tools = [
        "npm", "pnpm", "yarn", "bun", "deno", "make", "just", "docker", "uv", "poetry", "python3", "cargo", "go",
        "swift",
        "gradle", "mvn", "mix", "php"
    ]
    /// The likeliest dev server first: what ⌘R guesses when nothing was run in the project yet.
    static let runNames = [
        "dev", "start", "serve", "runserver", "uvicorn", "flask", "phx.server", "bin/dev", "web", "server", "bootRun",
        "run", "up", "main.py", "app.py"
    ]

    /// Files as \036path\037text (a mark has no text), Go's cmd/* folders as marks, then \035 and the programs found.
    static var script: String {
        let quoted = { (names: [String]) in names.map(ShellQuote.word).joined(separator: " ") }
        return #"for d in . * apps/* packages/* services/*; do [ -d "$d" ] || continue; "#
            + #"case "${d##*/}" in node_modules|vendor|venv|dist|build|target|out|coverage) continue;; esac; "#
            + "for f in \(quoted(files)); do [ -f \"$d/$f\" ] && { printf '\\036%s\\037' \"$d/$f\"; head -c 65536 \"$d/$f\"; }; done; "
            + "for f in \(quoted(marks)); do [ -e \"$d/$f\" ] && printf '\\036%s\\037' \"$d/$f\"; done; "
            + #"for c in "$d"/cmd/*/; do [ -d "$c" ] && printf '\036%s\037' "${c%/}"; done; done; printf '\035'; "#
            + "for t in \(quoted(tools)); do command -v \"$t\" >/dev/null 2>&1 && echo \"$t\"; done; exit 0"
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
        var found = Found()
        let halves = out.split(separator: "\u{1D}", maxSplits: 1, omittingEmptySubsequences: false)
        for entry in (halves.first.map(String.init) ?? "").components(separatedBy: "\u{1E}").dropFirst() {
            let kv = entry.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard let path = kv.first, !path.isEmpty else { continue }
            found.files[path.hasPrefix("./") ? String(path.dropFirst(2)) : String(path)] =
                kv.count > 1 ? String(kv[1]) : ""
        }
        if halves.count > 1 {
            found.tools = Set(
                halves[1].split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        }
        return found
    }

    /// The folder a listed path is in: names with a "/" of their own (app/main.py, bin/dev) are matched first.
    static func folder(of path: String) -> String {
        for name in (files + marks).sorted(by: { $0.count > $1.count }) where path == name || path.hasSuffix("/" + name)
        {
            return path == name ? "" : String(path.dropLast(name.count + 1))
        }
        guard let range = path.range(of: "cmd/", options: .backwards) else { return "" }
        return String(path[..<range.lowerBound].dropLast(path[..<range.lowerBound].hasSuffix("/") ? 1 : 0))
    }

    /// Every folder's, its own folder first; a command found twice in one folder (a Makefile's `dev: npm run dev`) once.
    static func options(_ found: Found) -> [RunOption] {
        let folders = Set(found.files.keys.map(folder(of:))).sorted {
            ($0.isEmpty ? 0 : 1, $0) < ($1.isEmpty ? 0 : 1, $1)
        }
        let finders: [(Found, String) -> [RunOption]] = [node, make, compose, python, compiled, procfile, editorTasks]
        let all = folders.flatMap { dir in finders.flatMap { $0(found, dir) } }
        var seen = Set<String>()
        return Array(all.filter { seen.insert($0.folder + "\u{0}" + $0.command).inserted }.prefix(60))
    }

    /// The dev server ⌘R would pick: the best-ranked runnable one, its own folder before subfolders.
    static func guess(_ options: [RunOption]) -> String? {
        let order = { (entry: (offset: Int, element: RunOption)) in
            (rank(entry.element.name), entry.element.folder.isEmpty ? 0 : 1, entry.offset)
        }
        return options.enumerated().filter { $0.element.kind == "run" && $0.element.missing == nil }.min {
            order($0) < order($1)
        }?.element.id
    }

    static func rank(_ name: String) -> Int { runNames.firstIndex(of: name) ?? runNames.count }

    static func kind(_ name: String) -> String {
        let lowered = name.lowercased()
        if runNames.contains(name) { return "run" }
        if lowered.hasPrefix("test") || lowered == "spec" || lowered == "pytest" { return "test" }
        if lowered.hasPrefix("build") || lowered == "compile" { return "build" }
        if ["lint", "format", "fmt", "typecheck"].contains(where: lowered.hasPrefix) { return "lint" }
        return "other"
    }

    static func opt(
        _ found: Found, _ dir: String, _ source: String, _ name: String, _ command: String, kind: String? = nil,
        detail: String? = nil,
        tool: String? = nil
    ) -> RunOption {
        RunOption(
            id: [dir, source, name].joined(separator: "|"), name: name, command: command, folder: dir, source: source,
            kind: kind ?? Self.kind(name),
            detail: detail == command ? nil : detail,
            missing: tool.flatMap { t in found.tools.map { $0.contains(t) ? nil : t } ?? nil })
    }

    static func byRank(_ first: String, _ second: String) -> Bool { (rank(first), first) < (rank(second), second) }

    // MARK: the files

    /// package.json's scripts (its pre/post hooks left out) through its package manager, and deno.json's tasks. No
    /// node_modules here or above: installing them is an entry of its own.
    static func node(_ found: Found, _ dir: String) -> [RunOption] {
        var out: [RunOption] = []
        if let json = found.text(dir, "package.json").flatMap(JSONC.object) {
            let pm = manager(found, dir, json["packageManager"] as? String)
            let scripts = (json["scripts"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            let hooks = scripts.keys.filter { key in
                ["pre", "post"].contains { key.hasPrefix($0) && scripts[String(key.dropFirst($0.count))] != nil }
            }
            out += scripts.keys.filter { !hooks.contains($0) }.sorted(by: byRank)
                .map { opt(found, dir, "package.json", $0, "\(pm) run \($0)", detail: scripts[$0], tool: pm) }
            if !found.has(dir, "node_modules"), !found.has("", "node_modules") {
                out.append(opt(found, dir, "package.json", "install", "\(pm) install", kind: "install", tool: pm))
            }
        }
        for file in ["deno.json", "deno.jsonc"] {
            guard let tasks = found.text(dir, file).flatMap(JSONC.object)?["tasks"] as? [String: Any] else { continue }
            out += tasks.keys.sorted(by: byRank).map {
                opt(found, dir, file, $0, "deno task \($0)", detail: tasks[$0] as? String, tool: "deno")
            }
        }
        return out
    }

    /// package.json's packageManager, else the lock file here or in the workspace's folder (a monorepo's), else npm.
    static func manager(_ found: Found, _ dir: String, _ field: String?) -> String {
        if let name = field?.split(separator: "@").first.map(String.init),
            ["npm", "pnpm", "yarn", "bun"].contains(name)
        {
            return name
        }
        let locks = [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lock", "bun"), ("bun.lockb", "bun")]
        return [dir, ""].lazy.compactMap { place in locks.first { found.has(place, $0.0) }?.1 }.first ?? "npm"
    }

    // swiftlint:disable:next force_try
    static let makeTarget = try! NSRegularExpression(
        pattern: #"^([A-Za-z0-9][A-Za-z0-9_./-]*)\s*::?(?!=)(?:[^#\n]*##\s*(.*))?"#)
    // swiftlint:disable:next force_try
    static let justRecipe = try! NSRegularExpression(pattern: #"^@?([A-Za-z0-9][A-Za-z0-9_-]*)(?:\s+[^:=\n]*)?:(?!=)"#)

    /// A Makefile's targets ("## text" after one is its description) and a justfile's recipes.
    static func make(_ found: Found, _ dir: String) -> [RunOption] {
        var out: [RunOption] = []
        if let file = ["Makefile", "makefile", "GNUmakefile"].first(where: { found.has(dir, $0) }),
            let text = found.text(dir, file)
        {
            // `help` only prints the list this menu already is.
            for (name, about) in matches(makeTarget, text)
            where name != "help" && !out.contains(where: { $0.name == name }) {
                out.append(opt(found, dir, file, name, "make \(name)", detail: about, tool: "make"))
            }
        }
        if let file = ["justfile", "Justfile"].first(where: { found.has(dir, $0) }), let text = found.text(dir, file) {
            let words: Set = ["set", "export", "alias", "import", "mod"]
            for (name, _) in matches(justRecipe, text)
            where !words.contains(name) && !out.contains(where: { $0.name == name }) {
                out.append(opt(found, dir, file, name, "just \(name)", tool: "just"))
            }
        }
        return out.prefix(30).sorted { byRank($0.name, $1.name) }
    }

    /// Each line's first group and, when it matched, its second.
    static func matches(_ re: NSRegularExpression, _ text: String) -> [(String, String?)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let lineText = String(line)
            guard let match = re.firstMatch(in: lineText, range: NSRange(lineText.startIndex..., in: lineText)),
                let range = Range(match.range(at: 1), in: lineText)
            else { return nil }
            let about =
                match.numberOfRanges > 2
                ? Range(match.range(at: 2), in: lineText).map {
                    String(lineText[$0]).trimmingCharacters(in: .whitespaces)
                } : nil
            return (String(lineText[range]), about?.isEmpty == false ? about : nil)
        }
    }

    /// The whole compose file, then each service (its first published port beside it); a lone Dockerfile built and run.
    static func compose(_ found: Found, _ dir: String) -> [RunOption] {
        guard
            let file = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"].first(where: {
                found.has(dir, $0)
            }),
            let text = found.text(dir, file)
        else { return dockerfile(found, dir) }
        let services = Self.services(text)
        return [
            opt(
                found, dir, file, "up", "docker compose up", kind: "run",
                detail: services.map(\.name).joined(separator: ", "), tool: "docker")
        ]
            + services.map {
                opt(
                    found, dir, file, $0.name, "docker compose up \($0.name)", kind: "other",
                    detail: $0.port.map { ":\($0)" }, tool: "docker")
            }
    }

    // swiftlint:disable:next force_try
    static let portLine = try! NSRegularExpression(pattern: #"^\s*-\s*["']?(?:[\d.]+:)?(\d+)(?:-\d+)?:\d+"#)

    /// The keys under `services:` (at the first indent found there) and the first host port each publishes.
    static func services(_ text: String) -> [(name: String, port: String?)] {
        var out: [(name: String, port: String?)] = [], inside = false, indent: Int?
        for line in text.split(whereSeparator: \.isNewline).map(String.init)
        where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            let lead = line.prefix { $0 == " " }.count
            if lead == 0 {
                inside = line.hasPrefix("services:")
                continue
            }
            guard inside else { continue }
            if indent == nil { indent = lead }
            if lead == indent, line.hasSuffix(":") {
                out.append((line.trimmingCharacters(in: .whitespaces).dropLast().description, nil))
                continue
            }
            if let last = out.indices.last, out[last].port == nil, let (port, _) = matches(portLine, line).first {
                out[last].port = port
            }
        }
        return out
    }

    static func dockerfile(_ found: Found, _ dir: String) -> [RunOption] {
        guard let text = found.text(dir, "Dockerfile") else { return [] }
        let tag = (dir.isEmpty ? "app" : (dir as NSString).lastPathComponent).lowercased().filter {
            $0.isLetter || $0.isNumber || $0 == "-"
        }
        let port = text.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
            let words = line.split(separator: " ")
            return words.count > 1 && words[0].uppercased() == "EXPOSE"
                ? words[1].split(separator: "/").first.map(String.init) : nil
        }.first
        let publish = port.map { " -p \($0):\($0)" } ?? ""
        return [
            opt(
                found, dir, "Dockerfile", "docker", "docker build -t \(tag) . && docker run --rm -it\(publish) \(tag)",
                kind: "run", tool: "docker")
        ]
    }
}
