import Foundation
import Testing

/// The daemon runs programs in its slots (`theDaemonRunsProgramsThroughItsSlots`), its async functions too.
@Test func theDaemonsAsyncFunctionsRunNoProgramOnThePool() throws {
    // Straight in an async function, a program runs on one of Swift's few pool threads (a sync handler is offloaded
    // whole). Finding a program on the login PATH may run the login shell, for seconds.
    let blocking = try NSRegularExpression(pattern: #"LoginPath\.resolve\(|(?<!await )Subprocess\.run\("#)
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
