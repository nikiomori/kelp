import Foundation
import Testing

/// The daemon runs programs in its slots (`theDaemonRunsProgramsThroughItsSlots`), its async functions too.
@Test func theDaemonsAsyncFunctionsRunNoProgramOnThePool() throws {
    // Straight in an async function, a program runs on one of Swift's few pool threads (a sync handler is offloaded
    // whole). Finding a program on the login PATH, or reading that PATH (`childPath`), may run the login shell, for seconds.
    let blocking = try NSRegularExpression(
        pattern: #"LoginPath\.(resolve\(|value\b)|\bchildPath\b|(?<!await )Subprocess\.run\("#)
    let off = try NSRegularExpression(
        pattern: #"(offloads?\.run|\boffload|\bblocking|Task\.detached|detachNewThread)\s*(\([^)]*\))?\s*\{"#)
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
