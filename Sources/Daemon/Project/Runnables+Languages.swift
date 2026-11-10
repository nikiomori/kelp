import Core
import Foundation

// Python apps, the compiled languages' tools (cargo, go, swift, gradle, maven, mix) and Procfile processes.

extension Runnables {
    /// Django's runserver, a FastAPI or Flask app, pyproject's scripts and pytest — through uv or poetry when the project
    /// uses them, else its .venv, else the PATH's python3. requirements.txt with no .venv: making one is an entry of its own.
    static func python(_ found: Found, _ dir: String) -> [RunOption] {
        let py = found.text(dir, "pyproject.toml")
        guard
            py != nil
                || ["manage.py", "requirements.txt", "main.py", "app.py", "app/main.py"].contains(where: {
                    found.has(dir, $0)
                })
        else { return [] }
        let (prefix, tool): (String, String?) =
            found.has(dir, "uv.lock")
            ? ("uv run ", "uv")
            : found.has(dir, "poetry.lock")
                ? ("poetry run ", "poetry")
                : found.has(dir, ".venv") ? (".venv/bin/", nil) : ("", "python3")
        let source = py != nil ? "pyproject.toml" : found.has(dir, "requirements.txt") ? "requirements.txt" : "python"
        func run(_ program: String, _ args: String = "") -> String {
            prefix + (program == "python" && prefix.isEmpty ? "python3" : program) + (args.isEmpty ? "" : " " + args)
        }
        var out: [RunOption] = []
        if found.has(dir, "manage.py") {
            out += [
                opt(found, dir, "manage.py", "runserver", run("python", "manage.py runserver"), tool: tool),
                opt(found, dir, "manage.py", "test", run("python", "manage.py test"), tool: tool)
            ]
        }
        for (file, module) in [("app/main.py", "app.main"), ("main.py", "main"), ("app.py", "app")] where out.isEmpty {
            guard let text = found.text(dir, file) else { continue }
            if let appName = matches(fastAPI, text).first?.0 {
                out.append(
                    opt(found, dir, file, "uvicorn", run("uvicorn", "\(module):\(appName) --reload"), tool: tool))
            } else if !matches(flask, text).isEmpty {
                out.append(opt(found, dir, file, "flask", run("flask", "--app \(module) run --debug"), tool: tool))
            } else if !file.contains("/") {
                out.append(opt(found, dir, file, file, run("python", file), tool: tool))
            }
        }
        if let py {
            for section in ["[project.scripts]", "[tool.poetry.scripts]"] {
                guard let start = py.range(of: section) else { continue }
                let body = py[start.upperBound...].prefix { $0 != "[" }
                for line in body.split(whereSeparator: \.isNewline) {
                    let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count == 2, !kv[0].isEmpty else { continue }
                    let target = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    out.append(opt(found, dir, "pyproject.toml", kv[0], run(kv[0]), detail: target, tool: tool))
                }
            }
            if py.contains("pytest") {
                out.append(opt(found, dir, "pyproject.toml", "pytest", run("pytest"), tool: tool))
            }
        }
        if found.has(dir, "requirements.txt"), prefix.isEmpty {
            out.append(
                opt(
                    found, dir, source, "install", "python3 -m venv .venv && .venv/bin/pip install -r requirements.txt",
                    kind: "install", tool: "python3"))
        }
        return out
    }

    // swiftlint:disable:next force_try
    static let fastAPI = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*FastAPI\("#)
    // swiftlint:disable:next force_try
    static let flask = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*Flask\("#)

    /// cargo, go (each cmd/* program), swift, gradle / maven (Spring Boot's bootRun), mix (Phoenix), artisan, bin/dev.
    static func compiled(_ found: Found, _ dir: String) -> [RunOption] {
        var out: [RunOption] = []
        if found.has(dir, "Cargo.toml") {
            out += ["run", "test", "build"].map { opt(found, dir, "Cargo.toml", $0, "cargo \($0)", tool: "cargo") }
        }
        if found.has(dir, "go.mod") {
            if found.has(dir, "main.go") { out.append(opt(found, dir, "go.mod", "run", "go run .", tool: "go")) }
            let cmds = found.files.keys.filter { folder(of: $0) == dir && $0.contains("cmd/") && found.files[$0] == "" }
                .sorted()
            out += cmds.map { path in
                let name = (path as NSString).lastPathComponent
                return opt(found, dir, "go.mod", name, "go run ./cmd/\(name)", kind: "run", tool: "go")
            }
            out += [
                opt(found, dir, "go.mod", "test", "go test ./...", tool: "go"),
                opt(found, dir, "go.mod", "build", "go build ./...", tool: "go")
            ]
        }
        if found.has(dir, "Package.swift") {
            out += ["run", "test", "build"].map { opt(found, dir, "Package.swift", $0, "swift \($0)", tool: "swift") }
        }
        if let file = ["build.gradle.kts", "build.gradle"].first(where: { found.has(dir, $0) }),
            let text = found.text(dir, file)
        {
            let (gradle, tool) = found.has(dir, "gradlew") ? ("./gradlew", nil as String?) : ("gradle", "gradle")
            let task = text.contains("springframework.boot") ? "bootRun" : text.contains("application") ? "run" : nil
            out += (task.map { [$0] } ?? []).map { opt(found, dir, file, $0, "\(gradle) \($0)", tool: tool) }
            out.append(opt(found, dir, file, "test", "\(gradle) test", tool: tool))
        }
        if let pom = found.text(dir, "pom.xml") {
            if pom.contains("spring-boot") {
                out.append(opt(found, dir, "pom.xml", "run", "mvn spring-boot:run", tool: "mvn"))
            }
            out.append(opt(found, dir, "pom.xml", "test", "mvn test", tool: "mvn"))
        }
        if let mix = found.text(dir, "mix.exs") {
            if mix.contains(":phoenix") {
                out.append(opt(found, dir, "mix.exs", "phx.server", "mix phx.server", tool: "mix"))
            }
            out.append(opt(found, dir, "mix.exs", "test", "mix test", tool: "mix"))
            if !found.has(dir, "deps") {
                out.append(opt(found, dir, "mix.exs", "install", "mix deps.get", kind: "install", tool: "mix"))
            }
        }
        if found.has(dir, "artisan") {
            out.append(opt(found, dir, "artisan", "serve", "php artisan serve", kind: "run", tool: "php"))
        }
        if found.has(dir, "bin/dev") { out.append(opt(found, dir, "bin/dev", "bin/dev", "bin/dev")) }
        return out
    }

    /// Each process of a Procfile (Procfile.dev first: it's the one for running locally).
    static func procfile(_ found: Found, _ dir: String) -> [RunOption] {
        ["Procfile.dev", "Procfile"].flatMap { file in
            (found.text(dir, file) ?? "").split(whereSeparator: \.isNewline).compactMap { line -> RunOption? in
                let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2, !kv[0].isEmpty, !kv[0].hasPrefix("#"), !kv[1].isEmpty else { return nil }
                return opt(found, dir, file, kv[0], kv[1])
            }
        }
    }
}
