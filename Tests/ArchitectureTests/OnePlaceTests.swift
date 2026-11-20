import Foundation
import Testing

/// How many times `pattern` matches the code (comments and strings left out) of `dirs`.
func count(_ pattern: String, in dirs: [String]) throws -> Int {
    let re = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    return sources(dirs).map { f in
        let code = codeOnly(f.text)
        return re.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }.reduce(0, +)
}

/// A kelp-vm machine's state moves in one place (`Lifecycle.move`): written here and there, its moves were where the
/// runtimes' races hid. Left: that one, and each runtime's first state read off its folder as it's made.
@Test func aMachinesStateMovesInOnePlace() throws {
    let writes = try count(#"(^|[^.\w])(self\.)?state = "#, in: ["Sources/KelpVM"])
    #expect(writes == 3, "state written \(writes) times in kelp-vm: through Lifecycle.move")
}

/// Whether a path is on another machine is asked feature by feature (`remotes.of`, `RemoteHost.of`): each new feature
/// that asks itself shipped local-only first, then a fix for its remote projects followed. The counts only go down: new
/// work goes through the one place once there is one.
@Test func remoteIsDecidedInFewerPlaces() throws {
    let daemon = try count(#"\bremotes\.(of|containing)\("#, in: ["Sources/Daemon", "Sources/GitKit"])
    let app = try count(#"\bRemoteHost\.of\("#, in: appDirs)
    #expect(daemon == 99, "remotes.of / remotes.containing in the daemon and GitKit: \(daemon)")
    #expect(app == 31, "RemoteHost.of in the app: \(app)")
}

/// Kelp's home folders are named in `Paths` (`Paths.agents(in:)` for a home given, as the daemon's): spelled out here
/// and there, a rename would have to find each.
@Test func homeFoldersAreNamedInPaths() {
    let spelled = sources(["Sources"]).filter { !$0.path.hasSuffix("/Core/System/Paths.swift") }.filter {
        $0.text.range(of: #"appendingPathComponent\("(agents|agent-skills|extensions)"\)"#, options: .regularExpression)
            != nil
    }.map(\.path)
    #expect(spelled == [], "through Paths: \(spelled)")
}

/// Claude Code and Codex are named by `Session.claudeAgent` / `codexAgent` where an agent's id is meant: spelled out,
/// a branch for one of them hides from a search for its uses. Left: the two declarations and the programs' own names
/// (`claude`, `codex` on the PATH), a model's name and a plugin's prefix. Comments don't count.
@Test func claudeAndCodexAreNamedByTheirIds() {
    let spelled = sources(["Sources"]).map { file in
        file.text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .map { $0.matches(of: #/"(claude|codex)"/#).count }.reduce(0, +)
    }.reduce(0, +)
    #expect(spelled <= 12, "\"claude\" / \"codex\" spelled \(spelled) times: name an agent by Session.claudeAgent")
    #expect(spelled >= 12, "fewer now (\(spelled)): lower the count")
}
