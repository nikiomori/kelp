import Core
import Foundation
import GitKit

extension CIRuns {
    private static let maxFailures = 100, maxMessages = 5

    /// What broke, from the text of a failed log (`readable`, the whole of it). Reads the formats of XCTest, Swift Testing
    /// and compilers that say `file:line:col: error:`. Limit: other runners (pytest, jest, go test) fall to `lastLines`.
    public static func report(log text: String) -> Report {
        var found = Found(), lines: [Substring] = [], testCases = 0, runTests = 0
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Test Case '"), line.hasSuffix("' started.") {
                testCases += 1
                continue
            }
            if !line.contains(" error: "), !line.contains("Test ") {
                lines.append(line)
                continue
            }
            if let n = line.firstMatch(of: /^. Test run with (\d+) tests?/) { runTests += Int(n.1) ?? 0 }
            if !found.read(line) { lines.append(line) }
        }
        var r = Report(failures: found.failures, more: found.more, log: GitHub.tail(text))
        r.tests = testCases + runTests > 0 ? testCases + runTests : nil
        if r.failures.isEmpty { (r.exitCode, r.lastLines) = ending(of: lines) }
        return r
    }

    /// How a log ended: the exit code in its last lines, and up to three lines before it.
    private static func ending(of lines: [Substring]) -> (Int?, [String]) {
        var rest = lines[...]
        while rest.last?.allSatisfy(\.isWhitespace) == true { rest.removeLast() }
        guard let last = rest.last else { return (nil, []) }
        let code = last.firstMatch(of: /exit code (\d+)/).flatMap { Int($0.1) }
        if code != nil { rest.removeLast() }
        let text = rest.filter { !$0.hasPrefix("▸ ") && !$0.allSatisfy(\.isWhitespace) }
        return (code, text.suffix(3).map(String.init))
    }

    /// The failures so far, one for each test or compiler line, in the order the log names them.
    private struct Found {
        var failures: [Failure] = [], more = 0
        private var seen: [String: Int] = [:]

        /// False: not a line about a failure.
        mutating func read(_ line: Substring) -> Bool {
            if let m = line.wholeMatch(of: /(.+?):(\d+): error: -\[(\S+) (\S+)\] : (.*)/) {
                let suite = m.3.split(separator: ".").last.map(String.init)
                add(test: String(m.4), suite: suite, file: String(m.1), line: Int(m.2), message: String(m.5))
            } else if let m = line.wholeMatch(of: /✘ Test (.+?) recorded an issue at (\S+?):(\d+):\d+: (.*)/) {
                add(test: String(m.1), suite: nil, file: String(m.2), line: Int(m.3), message: String(m.4))
            } else if let m = line.wholeMatch(of: /(.+?):(\d+):\d+: error: (.*)/) {
                add(test: nil, suite: nil, file: String(m.1), line: Int(m.2), message: String(m.3))
            } else if let m = line.wholeMatch(of: /Test Case '-\[(\S+) (\S+)\]' failed .*/) {
                // A test can fail with no line of its own (a crash, a timeout): its name is still worth saying.
                add(
                    test: String(m.2), suite: m.1.split(separator: ".").last.map(String.init), file: nil, line: nil,
                    message: nil)
            } else if let m = line.wholeMatch(of: /✘ Test (.+?) failed after .*/), !m.1.hasPrefix("run with") {
                add(test: String(m.1), suite: nil, file: nil, line: nil, message: nil)
            } else {
                return false
            }
            return true
        }

        private mutating func add(test: String?, suite: String?, file: String?, line: Int?, message: String?) {
            let file = file.map(CIRuns.repoPath)
            // A compiler says one error at each column of a line, and says it again in each build pass.
            let key = test.map { "\(suite ?? "").\($0)" } ?? "\(file ?? ""):\(line ?? 0):\(message ?? "")"
            guard let i = seen[key] else {
                guard failures.count < CIRuns.maxFailures else {
                    more += 1
                    return
                }
                seen[key] = failures.count
                failures.append(
                    Failure(test: test, suite: suite, file: file, line: line, messages: message.map { [$0] } ?? []))
                return
            }
            guard let message, failures[i].messages.count < CIRuns.maxMessages else { return }
            if failures[i].line == nil {
                failures[i].file = file
                failures[i].line = line
            }
            let said = line == failures[i].line ? message : ":\(line ?? 0) \(message)"
            if !failures[i].messages.contains(said) { failures[i].messages.append(said) }
        }
    }

    /// A path on the runner, as a path in the project: "/Users/runner/work/App/App/Tests/A.swift" → "Tests/A.swift".
    static func repoPath(_ path: String) -> String {
        guard let m = path.firstMatch(of: /\/(?:work|builds)\/[^\/]+\/[^\/]+\//) else { return path }
        return String(path[m.range.upperBound...])
    }

    /// Swift Testing names a file without its folder: the project knows where it is, if only one is called that.
    static func located(_ r: Report, cwd: String) -> Report {
        var r = r, known: [String: String?] = [:]
        for i in r.failures.indices {
            guard let f = r.failures[i].file, !f.contains("/") else { continue }
            if known[f] == nil {
                let paths = trackedFiles(named: f, cwd: cwd)
                known[f] = .some(paths.count == 1 ? paths[0] : nil)
            }
            if let path = known[f] ?? nil { r.failures[i].file = path }
        }
        return r
    }

    /// A probe: no git here (a folder that isn't a clone) means no such file.
    private static func trackedFiles(named name: String, cwd: String) -> [String] {
        do {
            return try Git.run(["ls-files", "--", ":(glob)**/" + name], cwd: cwd).split(separator: "\n").map(
                String.init)
        } catch { return [] }
    }
}
