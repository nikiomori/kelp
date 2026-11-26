import Foundation
import Testing

/// The daemon runs programs in its slots (`theDaemonRunsProgramsThroughItsSlots`), its async functions too.
@Test func theDaemonsAsyncFunctionsRunNoProgramOnThePool() throws {
    // Straight in an async function, a program runs on one of Swift's few pool threads (a sync handler is offloaded
    // whole). Finding a program on the login PATH, or reading that PATH (`childPath`), may run the login shell, for seconds.
    // So does any function of GitKit's or Integrations' that runs git, gh or ssh: all of theirs but the ones that only
    // read what they're given (`Git.isDirty(_:in:)`, a type's init) or a folder's files (`Git.nestedRepos`,
    // `Git.headBranch`: a listing and a HEAD file, no program).
    let blocking = try NSRegularExpression(
        pattern: #"LoginPath\.(resolve\(|value\b)|\bchildPath\b|(?<!await )Subprocess\.(run|checked|output)\("#
            + #"|\b(?:Git|GitHub|GitLab|CIRuns|ProjectFiles|HostRepo|RepoFilters|BitbucketClient)\."#
            + #"(?!isDirty\([^)]*\bin:|nestedRepos\(|headBranch\()[a-z]\w*\("#
    )
    let off = try NSRegularExpression(
        pattern:
            #"(offloads?\.run|\boffload(?:ed)?|\bblocking|Task\.detached|detachNewThread)\s*(\([^)]*\))?\s*\(?\s*\{"#)
    let asyncFunc = try NSRegularExpression(pattern: #"\bfunc\b[^{]*?\basync\b[^{]*\{"#)
    func block(_ s: [Character], from start: Int) -> Int {   // the index past the brace that closes the one before start
        var depth = 1, i = start
        while depth > 0, i < s.count {
            depth += s[i] == "{" ? 1 : s[i] == "}" ? -1 : 0
            i += 1
        }
        return i
    }
    func found(_ re: NSRegularExpression, _ s: String) -> [NSRange] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map(\.range)
    }
    let onThePool = sources(["Sources/Daemon"]).flatMap { f -> [String] in
        let code = codeOnly(f.text), chars = Array(code.utf16).map { Character(UnicodeScalar($0) ?? " ") }
        return found(asyncFunc, code).compactMap { head -> String? in
            var body = String(chars[head.upperBound..<block(chars, from: head.upperBound)])
            while let closure = found(off, body).first {   // what runs in a slot or a thread of its own goes
                let all = Array(body.utf16).map { Character(UnicodeScalar($0) ?? " ") }
                body = String(all[..<closure.location]) + String(all[block(all, from: closure.upperBound)...])
            }
            return found(blocking, body).isEmpty ? nil : f.path
        }
    }
    #expect(onThePool == [], "a program run in an async function, outside `offload`")
}

/// Handlers counted by what their service reaches of the daemon (`daemon.sessions`, as Handlers.swift hands it): one
/// handed all of `Sessions` (`AgentAddons(sessions:)` was), or keeping all of it (`let sessions: Sessions`), answers for
/// Sessions by another name; one handed a part of it (`daemon.sessions.setup`) reaches only that part.
func handlersByRoot(_ byService: [String: Int]) throws -> [String: Int] {
    let daemon = sources(["Sources/Daemon"])
    let handing = try #require(daemon.first { $0.path == "Sources/Daemon/Server/Handlers.swift" })
    let keeping = Set(daemon.flatMap { keepsSessions(codeOnly($0.text)) })
    var byRoot: [String: Int] = [:]
    for service in handing.text.matches(of: #/extension (\w+): DaemonService \{/#) {
        let body = handing.text[service.range.upperBound..<closing(handing.text, from: service.range.upperBound)]
        var roots = Set(body.matches(of: #/daemon\??\.(\w+)(?![\w.(])/#).map { String($0.1) })
        if keeping.contains(String(service.1)) { roots.insert("sessions") }
        for root in roots { byRoot[root, default: 0] += byService[String(service.1)] ?? 0 }
    }
    return byRoot
}

/// The types whose stored properties hold all of `Sessions` (a `let` of its own, or one of several on a line).
func keepsSessions(_ code: String) -> [String] {
    code.matches(of: #/(?:struct|class|actor) (\w+)\b[^{\n]*\{/#).compactMap { type in
        let body = code[type.range.upperBound..<closing(code, from: type.range.upperBound)]
        let keeps = body.split(separator: "\n").contains {
            $0.wholeMatch(of: #/    (?:(?:private|weak|unowned) )*(?:let|var) [^=(]*\b\w+: Sessions\b(?![.?\w])[^=]*/#)
                != nil
        }
        return keeps && type.1 != "Sessions" ? String(type.1) : nil
    }
}

/// The index past the brace that closes the one just before `start`.
func closing(_ text: String, from start: String.Index) -> String.Index {
    var depth = 1, end = start
    while depth > 0, end < text.endIndex {
        depth += text[end] == "{" ? 1 : text[end] == "}" ? -1 : 0
        end = text.index(after: end)
    }
    return end
}

/// What the daemon runs on is handed to it (`Daemon(root:)`, its `Remotes`, `LSPHost`'s delays): nothing in the code it
/// runs reads KELP_HOME's folders from the environment, keeps state in a static or opts out of the isolation checks. Two
/// daemons in one process (tests) shared those, and the one set last won. (GitKit runs git on a remote project's host
/// only when it's given the daemon's `Remotes`: no GitKit function has a default for it, so the compiler checks that.)
@Test func theDaemonKeepsNoProcessGlobals() throws {
    let modules = [
        "Sources/Daemon", "Sources/Core", "Sources/GitKit", "Sources/LSPKit", "Sources/Agents", "Sources/AgentData",
        "Sources/Integrations"
    ]
    let files = sources(modules).map { (path: $0.path, code: codeOnly($0.text)) }
    func found(_ pattern: String, in files: [(path: String, code: String)]) throws -> [(
        path: String, code: String, at: Range<String.Index>
    )] {
        let re = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        return files.flatMap { f in
            re.matches(in: f.code, range: NSRange(f.code.startIndex..., in: f.code)).compactMap { m in
                Range(m.range, in: f.code).map { (f.path, f.code, $0) }
            }
        }
    }
    func named(_ hits: [(path: String, code: String, at: Range<String.Index>)]) -> [String] {
        hits.map { "\($0.path):\($0.code[..<$0.at.lowerBound].filter { $0 == "\n" }.count + 1)" }
    }
    let unsafe = try found(#"nonisolated\(unsafe\)"#, in: files)
    let statics = try found(#"\bstatic var \w+(?:\s*:\s*[^={\n]+)?\s*="#, in: files)
    let home = try found(
        #"\bPaths\.(?:root|socket|agents|extensions|agentSkills|scratch)\b(?!\(in:)|\bfunc daemonError\(in root: URL ="#,
        in: files.filter { $0.path != "Sources/Core/System/Paths.swift" })
    #expect(named(unsafe) == [], "nonisolated(unsafe)")
    #expect(named(statics) == [], "state in a static var")
    #expect(named(home) == [], "KELP_HOME's folders from the environment")
    // A `let` that holds a lock is state too, a static's or a file's. Each says why every daemon in a process may share it.
    let shared: [String: String] = [
        "Sources/Integrations/HostRepo.swift: known": "a remote folder's GitHub repository, keyed by the folder's path",
        "Sources/Integrations/HostRepo.swift: reading": "one read of a folder's origin at a time, whoever asks",
        "Sources/GitKit/Git.swift: cache":
            "a repository's filter names, keyed by its config and read again when it changes",
        "Sources/GitKit/Snapshot.swift: indexFiles":
            "a folder's index file, keyed by its path and asked again once gone",
        "Sources/GitKit/LineStats.swift: lineCounts": "a file's line count, keyed by its path, size and date",
        "Sources/GitKit/Files.swift: searching":
            "the search box's rg in each folder, keyed by the folder: a newer search there stops it, whoever started it",
        "Sources/Core/Extensions/ExtensionFiles.swift: digests":
            "an extension folder's digest, keyed by its path and its files' stats",
        "Sources/Core/Artifacts/Artifacts.swift: versionLock":
            "one version kept at a time, whichever of a turn's end, hand edits or a send asks: no two take one number",
        "Sources/Core/Artifacts/ArtifactMarks.swift: lock":
            "one change at a time to a page's marks file, which is one file whichever daemon writes it",
        "Sources/Core/System/Subprocess.swift: running":
            "the programs this process started: a fact of the process itself",
        "Sources/AgentData/ClaudeBuiltIns.swift: known":
            "the skills built into the Claude Code on this Mac, the same for all",
        "Sources/AgentData/ClaudeContext.swift: usages":
            "a transcript's context usage, keyed by its path, size and date",
        "Sources/AgentData/Usage.swift: rollouts": "a Codex rollout's limits, keyed by its path, size and date",
        "Sources/Core/Artifacts/ArtifactPages.swift: pageUses":
            "what a page's copy uses beside it, keyed by its path, size and date"
    ]
    let locks = try found(
        #"(?:\bstatic |^(?:(?:private|fileprivate|public|package) )?)let (\w+)\s*[:=]\s*(?:OSAllocatedUnfairLock|Mutex|NSCache|NSLock|NSRecursiveLock|Atomic\w*|StatMemo)\b"#,
        in: files)
    let held = Set(
        locks.map { hit in
            "\(hit.path): \(hit.code[hit.at].firstMatch(of: /let (\w+)/).map { String($0.1) } ?? "")"
        })
    #expect(
        held.subtracting(shared.keys).sorted() == [], "a lock outside an instance: say why every daemon may share it")
    #expect(Set(shared.keys).subtracting(held).sorted() == [], "gone: take it off the list")
}
