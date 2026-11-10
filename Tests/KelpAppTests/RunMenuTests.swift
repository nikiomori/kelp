import AppKit
import Testing

@testable import BuiltinRun

private func row(_ name: String, _ command: String, kind: String = "other", file: String = "", folder: String = "")
    -> ScriptsMenu.Row
{
    ScriptsMenu.Row(id: name, name: name, command: command, kind: kind, file: file, folder: folder)
}

/// The Run menu orders a program's commands by what they're for: run.detect's kind, then the name for what kinds
/// don't say (deploys and releases; smoke and e2e tests), installs first. A Dockerfile's "run" builds an image: not
/// the everyday server.
@MainActor @Test func aCommandsPurposeComesFromItsKindThenItsName() {
    #expect(ScriptsMenu.purpose(row("dev", "npm run dev", kind: "run")) == .run)
    #expect(ScriptsMenu.purpose(row("run", "docker build .", kind: "run", file: "Dockerfile")) == .other)
    #expect(ScriptsMenu.purpose(row("test", "npm test", kind: "test")) == .test)
    #expect(ScriptsMenu.purpose(row("e2e:ci", "playwright test")) == .test)
    #expect(ScriptsMenu.purpose(row("lint", "eslint .", kind: "lint")) == .build)
    #expect(ScriptsMenu.purpose(row("deploy:prod", "fly deploy", kind: "build")) == .deploy)   // the name says more
    #expect(ScriptsMenu.purpose(row("setup", "./setup.sh", kind: "run")) == .install)
    var install = row("Install", "npm ci", kind: "install")
    install.install = true
    #expect(ScriptsMenu.purpose(install) == .install)
}

/// Its symbol follows the purpose; one that runs now is a green circled ▶, whatever it is; the rest by name.
@MainActor @Test func aCommandsSymbolSaysWhatItIsFor() {
    #expect(ScriptsMenu.glyph(row("lint", "eslint .", kind: "lint")).0 == "checkmark.circle.fill")
    #expect(ScriptsMenu.glyph(row("build", "make", kind: "build")).0 == "hammer.fill")
    #expect(ScriptsMenu.glyph(row("rollback", "fly releases rollback")).0 == "arrow.uturn.backward.circle.fill")
    #expect(ScriptsMenu.glyph(row("db:migrate", "rails db:migrate")).0 == "cylinder")
    #expect(ScriptsMenu.glyph(row("web", "docker compose up", file: "compose.yaml")).0 == "shippingbox")
    #expect(ScriptsMenu.glyph(row("whatever", "x")).0 == "terminal")
    var running = row("test", "npm test", kind: "test")
    running.running = true
    #expect(ScriptsMenu.glyph(running) == ("play.circle.fill", .systemGreen))
}

/// Where a command comes from, in a word: its program as people call it, and the folder it runs in.
@MainActor @Test func aCommandsSourceIsItsProgramAndFolder() {
    #expect(ScriptsMenu.source(row("dev", "npm run dev", folder: "apps/web")) == "npm · web")
    #expect(ScriptsMenu.source(row("up", "docker compose up")) == "compose")
    #expect(ScriptsMenu.source(row("t", ".venv/bin/pytest")) == "venv")
    #expect(ScriptsMenu.source(row("s", "./scripts/go.sh")) == "scripts/go.sh")
    #expect(
        ScriptsMenu.source(ScriptsMenu.Row(id: "kelp:run", name: "run", command: "make dev", file: ".kelp.yaml"))
            == ".kelp.yaml")
}

/// A project's commands file as the trust question names it: from its first folder that starts with a dot.
@MainActor @Test func aCommandsFileIsNamedFromItsDotFolder() {
    #expect(ScriptsMenu.shortName("/p/.codex/environments/environment.toml") == ".codex/environments/environment.toml")
    #expect(ScriptsMenu.shortName("/Users/a/p/.conductor/settings.toml") == ".conductor/settings.toml")
    #expect(ScriptsMenu.shortName("/Users/a/p/conductor.json") == "conductor.json")
}
