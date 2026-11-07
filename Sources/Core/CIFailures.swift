import Foundation

extension CIRuns {
    /// One thing that broke: a test, or a compiler's error (no `test`), with where and what, read from a job's log.
    public struct Failure: Codable, Sendable, Equatable {
        public var test: String?, suite: String?
        /// Relative to the project where the log says enough to tell.
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
        /// "Tests/AppTests.swift:12".
        public var place: String? { file.map { f in line.map { "\(f):\($0)" } ?? f } }
    }

    /// What a failed log says. `failures` comes from the whole log, before `log` keeps only its tail.
    public struct Report: Codable, Sendable, Equatable {
        public var failures: [Failure]
        /// Failures left out past the cap.
        public var more: Int
        /// Tests that ran, when the log counts them.
        public var tests: Int?
        /// For a log in no known format: how it ended, and the lines before that.
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

        /// What an agent gets: everything that broke, wherever it sits in the log, then the log's tail.
        public var forAgent: String { summary.isEmpty ? log : summary + "\n\n" + log }

        public static func text(of failures: [Failure], more: Int = 0) -> String {
            let lines = failures.map { f in
                let name = [f.suite, f.test].compactMap { $0 }.joined(separator: ".")
                let head = [f.place, name.isEmpty ? nil : name].compactMap { $0 }.joined(separator: " ")
                return ([head] + f.messages.map { "  " + $0 }).joined(separator: "\n")
            }
            return (lines + (more > 0 ? ["+\(more)"] : [])).joined(separator: "\n")
        }
    }
}
