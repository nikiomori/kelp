import Foundation

extension CIRuns {
    /// One thing that broke, read from a job's log. It is a test, or a compiler error (with no `test`), along with its
    /// location and its messages.
    public struct Failure: Codable, Sendable, Equatable {
        public var test: String?, suite: String?
        /// The file is relative to the project when the log says enough to tell.
        public var file: String?, line: Int?
        public var messages: [String]
        public init(
            test: String? = nil, suite: String? = nil, file: String? = nil, line: Int? = nil, messages: [String] = []
        ) {
            self.test = test
            self.suite = suite
            self.file = file
            self.line = line
            self.messages = messages
        }
        /// The location as "file:line", such as "Tests/AppTests.swift:12".
        public var place: String? { file.map { f in line.map { "\(f):\($0)" } ?? f } }
    }

    /// What a failed log says. `failures` is read from the whole log, and `log` keeps only its tail.
    public struct Report: Codable, Sendable, Equatable {
        public var failures: [Failure]
        /// The number of failures left out because of the cap.
        public var more: Int
        /// The number of tests that ran, when the log counts them.
        public var tests: Int?
        /// For a log in no known format, its exit code and its last lines.
        public var exitCode: Int?, lastLines: [String]
        /// The log's tail.
        public var log: String
        public init(
            failures: [Failure] = [], more: Int = 0, tests: Int? = nil, exitCode: Int? = nil, lastLines: [String] = [],
            log: String = ""
        ) {
            self.failures = failures
            self.more = more
            self.tests = tests
            self.exitCode = exitCode
            self.lastLines = lastLines
            self.log = log
        }

        /// The failures alone, to copy or to read at a glance.
        public var summary: String { Report.text(of: failures, more: more) }

        /// The text an agent gets: everything that broke, wherever it was in the log, then the log's tail.
        public var forAgent: String { summary.isEmpty ? log : summary + "\n\n" + log }

        public static func text(of failures: [Failure], more: Int = 0) -> String {
            let lines = failures.map { failure in
                let name = [failure.suite, failure.test].compactMap { $0 }.joined(separator: ".")
                let head = [failure.place, name.isEmpty ? nil : name].compactMap { $0 }.joined(separator: " ")
                return ([head] + failure.messages.map { "  " + $0 }).joined(separator: "\n")
            }
            return (lines + (more > 0 ? ["+\(more)"] : [])).joined(separator: "\n")
        }
    }
}
