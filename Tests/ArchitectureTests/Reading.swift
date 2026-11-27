import Foundation

// How the rules read the sources: each folder once a run, each file's code once.

/// The app: its target (main.swift and the list of built-ins), the shell (KelpKit) and the built-ins' modules.
let appDirs = ["Sources/KelpApp", "Sources/KelpKit", "Sources/Builtins"]

/// Every .swift file under these folders (relative to the repo), with its text. Each folder is read once a run: the
/// rules read the same ones again and again.
func sources(_ dirs: [String]) -> [(path: String, text: String)] {
    dirs.flatMap { dir in
        memo.withLock {
            if let read = $0.sources[dir] { return read }
            let base = root.appendingPathComponent(dir)
            let files =
                FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
                ?? []
            let read = files.filter { $0.pathExtension == "swift" }.compactMap { u in
                (try? String(contentsOf: u, encoding: .utf8)).map { (dir + u.path.dropFirst(base.path.count), $0) }
            }
            $0.sources[dir] = read
            return read
        }
    }
}

/// What `sources` and `codeOnly` worked out already, shared by the tests (they run side by side).
private let memo = Memo()
private final class Memo: @unchecked Sendable {   // everything under `lock`
    private let lock = NSLock()
    private var state = (sources: [String: [(path: String, text: String)]](), code: [String: String]())
    func withLock<T>(_ body: (inout (sources: [String: [(path: String, text: String)]], code: [String: String])) -> T)
        -> T
    {
        lock.withLock { body(&state) }
    }
}

func matches(_ pattern: String, in dirs: [String]) throws -> [String] {
    let re = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    return sources(dirs).flatMap { f in
        re.matches(in: f.text, range: NSRange(f.text.startIndex..., in: f.text)).map { m in
            "\(f.path):\(f.text[..<(Range(m.range, in: f.text)?.lowerBound ?? f.text.startIndex)].filter { $0 == "\n" }.count + 1)"
        }
    }
}

/// A Swift file's code without its comments and string literals (their words could be any name); lines stay where they were.
func codeOnly(_ s: String) -> String {
    if let code = memo.withLock({ $0.code[s] }) { return code }
    let code = stripped(s)
    memo.withLock { $0.code[s] = code }
    return code
}

private func stripped(_ s: String) -> String {
    var out = "", i = s.startIndex
    func skip(to end: String.Index) {
        out += s[i..<end].filter { $0 == "\n" }
        i = end
    }
    while i < s.endIndex {
        let rest = s[i...]
        if rest.hasPrefix("//") {
            skip(to: rest.firstIndex(of: "\n") ?? s.endIndex)
        } else if rest.hasPrefix("/*") {
            skip(to: rest.range(of: "*/")?.upperBound ?? s.endIndex)
        } else if rest.hasPrefix("\"\"\"") {
            skip(to: rest.dropFirst(3).range(of: "\"\"\"")?.upperBound ?? s.endIndex)
        } else if rest.first == "\"" {
            var j = rest.index(after: rest.startIndex)
            while j < s.endIndex, s[j] != "\"", s[j] != "\n" {
                j = s.index(j, offsetBy: s[j] == "\\" && s.index(after: j) < s.endIndex ? 2 : 1)
            }
            skip(to: j < s.endIndex && s[j] == "\"" ? s.index(after: j) : j)
        } else {
            out.append(s[i])
            i = s.index(after: i)
        }
    }
    return out
}
