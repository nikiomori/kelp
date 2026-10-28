import Foundation
import os
import Testing
import Core
@testable import Daemon

/// What the detection script prints, made by hand: files, marks, then the programs found.
private func printed(_ files: [String: String], tools: [String]) -> String {
    files.map { "\u{1E}./\($0.key)\u{1F}\($0.value)" }.joined() + "\u{1D}" + tools.joined(separator: "\n")
}

/// Each kind of project file turns into the commands it names, run the way the project runs them.
@Test func runOptionsFromProjectFiles() {
    let out = "Welcome to the host\n" + printed([
        "package.json": #"{"scripts": {"dev": "vite", "predev": "echo", "test": "vitest", "lint": "eslint ."}}"#,
        "pnpm-lock.yaml": "",
        "Makefile": "VAR := 1\n.PHONY: up\nup: ## start the db\n\tdocker compose up -d db\nbuild/%.o: x\nseed:\n\tpnpm seed\n",
        "compose.yaml": "services:\n  web:\n    ports:\n      - \"3000:3000\"\n  db:\n    image: postgres\nvolumes:\n  data:\n",
        "backend/pyproject.toml": "[project]\nname = \"api\"\n[project.scripts]\nadmin = \"api.cli:main\"\n[tool.pytest.ini_options]\n",
        "backend/uv.lock": "",
        "backend/app/main.py": "from fastapi import FastAPI\napi = FastAPI()\n",
        "cmd/tool": ""
    ], tools: ["pnpm", "make", "uv"])
    let options = Runnables.options(Runnables.parse(out))
    let by = Dictionary(options.map { ($0.id, $0) }) { a, _ in a }
    #expect(by["|package.json|dev"]?.command == "pnpm run dev" && by["|package.json|dev"]?.detail == "vite")
    #expect(by["|package.json|predev"] == nil, "a hook runs with its script, not on its own")
    #expect(by["|package.json|install"]?.kind == "install", "no node_modules: installing is offered apart")
    #expect(by["|package.json|test"]?.kind == "test")
    #expect(by["|Makefile|up"]?.detail == "start the db" && by["|Makefile|seed"]?.command == "make seed")
    #expect(!options.contains { $0.name == "VAR" || $0.name.contains("%") })
    #expect(by["|compose.yaml|up"]?.missing == "docker", "docker isn't on that PATH")
    #expect(by["|compose.yaml|web"]?.detail == ":3000" && by["|compose.yaml|db"] != nil && by["|compose.yaml|data"] == nil)
    #expect(by["backend|app/main.py|uvicorn"]?.command == "uv run uvicorn app.main:api --reload")
    #expect(by["backend|pyproject.toml|admin"]?.command == "uv run admin" && by["backend|pyproject.toml|pytest"]?.kind == "test")
    #expect(options.first?.folder == "", "the workspace's own folder first")
    #expect(Runnables.guess(options) == "|package.json|dev")
    // A folder whose only file names the folder by a path of its own (app/main.py) is still its project's.
    #expect(Runnables.folder(of: "backend/app/main.py") == "backend" && Runnables.folder(of: "app/main.py") == "")
    #expect(Runnables.parse("cut short\u{1E}./Makefile\u{1F}a:\n").tools == nil)
}

/// run.detect reads the workspace's files; run.start runs what it listed, in the folder it came from.
@Test func detectAndStartARun() async throws {
    let (d, c, _) = try daemon(); defer { d.stop() }
    let path = try makeRepo()
    try FileManager.default.createDirectory(atPath: path + "/tools", withIntermediateDirectories: true)
    try "hello:\n\ttouch HELLO\nserve:\n\t@echo Local: http://localhost:5173/\n".write(toFile: path + "/tools/Makefile", atomically: true, encoding: .utf8)
    try #"{"scripts": {"dev": "echo http://localhost:5173"}}"#.write(toFile: path + "/package.json", atomically: true, encoding: .utf8)
    let repo: Repo = try await c.call("repo.add", .obj(["path": .string(path)]), as: Repo.self)
    let w = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
    let found = try await c.call(RunDetect(worktreeId: w.id))
    #expect(found.guess == "|package.json|dev")
    #expect(found.options.contains { $0.id == "tools|Makefile|hello" && $0.folder == "tools" })
    let s = try await c.call(RunStart(worktreeId: w.id, id: "tools|Makefile|hello"))
    #expect(s.title == "tools › hello")
    #expect(try await waitFor { FileManager.default.fileExists(atPath: path + "/tools/HELLO") })
    await #expect(throws: (any Error).self) { try await c.call(RunStart(worktreeId: w.id, id: "|Makefile|gone")) }
    // The page a run prints comes as event.devserver, with the run's session.
    let pages = OSAllocatedUnfairLock<[DevServerEvent]>(initialState: [])
    c.onEvent = { e in if let e = e as? DevServerEvent { pages.withLock { $0.append(e) } } }
    let served = try await c.call(RunStart(worktreeId: w.id, id: "tools|Makefile|serve"))
    #expect(try await waitFor { pages.withLock { $0 }.contains { $0.session == served.id && $0.url == "http://localhost:5173/" } })
}

/// A remote project's files are read on its host, in one call through the shared connection.
@Test func detectOnARemoteHost() async throws {
    _ = localSSH
    let (d, c, _) = try daemon(); defer { d.stop() }
    let there = try makeRepo()
    try "serve:\n\ttrue\n".write(toFile: there + "/Makefile", atomically: true, encoding: .utf8)
    let repo = try await c.call(RepoAddRemote(host: "box", path: there))
    let w = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
    #expect(try await c.call(RunDetect(worktreeId: w.id)).options.map(\.id) == ["|Makefile|serve"])
}
