import Agents
import Core
import Foundation
import Testing

@testable import Daemon

/// The wrapper brings the container up (once), then runs the command there through `docker exec`: in the folder, as the
/// container's user, the environment by name only, the folders mounted at their own paths.
@Test func aCommandRunsInItsProjectsDevContainer() throws {
    let bin = tmp(), log = tmp().appendingPathComponent("calls").path
    func fake(_ name: String, _ body: String) throws {
        let file = bin.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    try fake(
        "devcontainer",
        #"echo "devcontainer $*" >> "$LOG"; echo '{"outcome":"success","containerId":"c1","remoteUser":"vscode"}'"#)
    // docker ps: nothing runs yet; docker exec: the command after the container's id, run here.
    try fake(
        "docker",
        #"""
        echo "docker $*" >> "$LOG"
        [ "$1" = exec ] || exit 0
        while [ "$1" != c1 ]; do shift; done; shift; exec "$@"
        """#)
    let folder = tmp().path
    let argv = DevContainer.wrap(
        ["sh", "-c", "echo ran in $(pwd)"], cwd: folder, in: (folder, "/p/main"),
        readOnly: ["/k/skills"], env: ["SECRET_X"])
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    p.currentDirectoryURL = URL(fileURLWithPath: folder)
    p.environment = [
        "PATH": bin.path + ":/usr/bin:/bin", "LOG": log, "SECRET_X": "s3cr3t", "TERM": "xterm-256color"
    ]
    p.standardOutput = out
    try p.run()
    p.waitUntilExit()
    let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let calls = try String(contentsOfFile: log, encoding: .utf8)
    #expect(printed.contains("Starting the dev container") && printed.contains("ran in"), "\(printed)")
    #expect(
        calls.contains(
            "devcontainer up --workspace-folder \(folder) --mount type=bind,source=\(folder),target=\(folder)"))
    #expect(calls.contains("--mount type=bind,source=/p/main,target=/p/main"))
    #expect(calls.contains("--mount type=bind,source=/k/skills,target=/k/skills,readonly"))
    #expect(calls.contains("docker exec -i -u vscode -w \(folder) -e SECRET_X -e TERM c1 sh -c"))
    #expect(!calls.contains("s3cr3t"), "a secret goes by name, never on a command line")
}

/// Inside, a terminal is the container's shell and Claude-style hooks report through the terminal, not tmux; the
/// folders an agent's command line names of Kelp's are mounted.
@Test func whatRunsInsideFitsTheContainer() throws {
    let shell = try DevContainer.inside(
        ["/bin/zsh", "-l"], AgentManifest(id: "shell", name: "Shell", command: "/bin/zsh"))
    #expect(shell.first == "sh" && shell.last?.contains("bash -l") == true)
    var claude = AgentManifest(id: "claude", name: "Claude Code", command: "claude")
    claude.hooks = .settingsFlag("--settings")
    let run = try DevContainer.inside(["claude", "--settings", "/k/hooks.json", "--plugin-dir", "/k/skills"], claude)
    let hooks = try #require(run.firstIndex(of: "--settings").map { run[$0 + 1] })
    #expect(hooks.contains("7501") && !hooks.contains("tmux") && !hooks.contains("/k/hooks.json"))
    #expect(DevContainer.named(in: run) == ["/k/skills"])
}

/// A project runs in its container only when the user says so and the folder has one.
@Test func onlyAProjectTurnedOnWithAConfigRunsInItsContainer() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let repo = try await c.call(RepoAdd(path: try makeRepo()))
    let setup = d.sessions.setup
    #expect(setup.devContainer(repo.path) == nil)
    try d.store.setDaemonState(Repo.devContainerKey, [repo.id])
    #expect(setup.devContainer(repo.path) == nil, "no devcontainer.json")
    try FileManager.default.createDirectory(atPath: repo.path + "/.devcontainer", withIntermediateDirectories: true)
    try "{}".write(toFile: repo.path + "/.devcontainer/devcontainer.json", atomically: true, encoding: .utf8)
    #expect(setup.devContainer(repo.path + "/sub")?.folder == repo.path)
    let run = try setup.launchArgv(
        ["/bin/zsh", "-l"], cwd: repo.path, manifest: AgentManifest(id: "shell", name: "Shell", command: "/bin/zsh"))
    #expect(run.first == "/bin/sh" && run[2].contains("--workspace-folder"))
}
