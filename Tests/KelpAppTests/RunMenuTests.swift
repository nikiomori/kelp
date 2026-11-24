import AppKit
import Core
import Testing

@testable import BuiltinRun
@testable import KelpKit

@MainActor private func row(
    _ name: String, _ command: String, kind: String = "other", file: String = "", folder: String = ""
)
    -> Runs.Row
{
    var made = Runs.Row(id: name, name: name, command: command, kind: kind, file: file, folder: folder)
    made.purpose = Runs.purpose(made)
    return made
}

/// The Run menu orders a program's commands by what they're for: run.detect's kind, then the name for what kinds
/// don't say (deploys and releases; smoke and e2e tests), installs first. A Dockerfile's "run" builds an image: not
/// the everyday server.
@MainActor @Test func aCommandsPurposeComesFromItsKindThenItsName() {
    #expect(Runs.purpose(row("dev", "npm run dev", kind: "run")) == .run)
    #expect(Runs.purpose(row("run", "docker build .", kind: "run", file: "Dockerfile")) == .other)
    #expect(Runs.purpose(row("test", "npm test", kind: "test")) == .test)
    #expect(Runs.purpose(row("e2e:ci", "playwright test")) == .test)
    #expect(Runs.purpose(row("lint", "eslint .", kind: "lint")) == .build)
    #expect(Runs.purpose(row("deploy:prod", "fly deploy", kind: "build")) == .deploy)   // the name says more
    #expect(Runs.purpose(row("setup", "./setup.sh", kind: "run")) == .install)
    var install = row("Install", "npm ci", kind: "install")
    install.install = true
    #expect(Runs.purpose(install) == .install)
}

/// A command that runs now shows its purpose in the purpose's colour (decision 83), not a green ▶ for everything.
@MainActor @Test func aRunningCommandShowsItsPurposesColour() {
    var running = row("test", "npm test", kind: "test")
    running.running = true
    #expect(Runs.glyph(running) == ("flask", .systemPurple))
}

/// Where a command comes from, in a word: its program as people call it, and the folder it runs in.
@MainActor @Test func aCommandsSourceIsItsProgramAndFolder() {
    #expect(Runs.source(row("dev", "npm run dev", folder: "apps/web")) == "npm · web")
    #expect(Runs.source(row("up", "docker compose up")) == "compose")
    #expect(Runs.source(row("t", ".venv/bin/pytest")) == "venv")
    #expect(Runs.source(row("s", "./scripts/go.sh")) == "scripts/go.sh")
    #expect(
        Runs.source(Runs.Row(id: "kelp:run", name: "run", command: "make dev", file: ".kelp.yaml"))
            == ".kelp.yaml")
}

/// A project's commands file as the trust question names it: from its first folder that starts with a dot.
@MainActor @Test func aCommandsFileIsNamedFromItsDotFolder() {
    #expect(Runs.shortName("/p/.codex/environments/environment.toml") == ".codex/environments/environment.toml")
    #expect(Runs.shortName("/Users/a/p/.conductor/settings.toml") == ".conductor/settings.toml")
    #expect(Runs.shortName("/Users/a/p/conductor.json") == "conductor.json")
}

/// A page a run printed reaches Run through the built-ins' events (`Contributions.events`), not a case of the shell's
/// own: the run's chip holds it for a click.
@MainActor @Test func aPageARunPrintedReachesRunThroughItsEvents() {
    let app = AppModel(builtins: [Builtins.run])
    app.extensions.reload()
    let runs = app.part { Runs(app: app) }
    runs.state.active["s"] = .init(workspace: "w", choice: "kelp:run")
    app.handle(DevServerEvent(worktree: "w", url: "http://localhost:3000", session: "s"))
    #expect(runs.state.active["s"]?.url == "http://localhost:3000")
}
