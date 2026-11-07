import Foundation

/// CI runs of one branch, the same for GitHub Actions (`gh run`) and GitLab pipelines (`glab api`).
public enum CIRuns {
    /// Finished without success (failed, timed out, cancelled…).
    public static func failed(_ status: String, _ conclusion: String?) -> Bool {
        status == "completed" && !["success", "skipped", "neutral", nil].contains(conclusion)
    }
    public struct Step: Codable, Sendable, Equatable {
        public var name: String
        public var status: String
        public var conclusion: String?
        /// Its place in the job, which a link to the step names.
        public var number: Int?, startedAt: String?, completedAt: String?
        public init(
            name: String, status: String, conclusion: String?, number: Int? = nil, startedAt: String? = nil,
            completedAt: String? = nil
        ) {
            self.name = name
            self.status = status
            self.conclusion = conclusion
            self.number = number
            self.startedAt = startedAt
            self.completedAt = completedAt
        }
        public var failed: Bool { CIRuns.failed(status, conclusion) }
    }
    public struct Job: Codable, Sendable, Equatable {
        public var id: Int, name: String, status: String, conclusion: String?, url: String?
        public var steps: [Step]
        public var startedAt: String?, completedAt: String?
        public init(
            id: Int, name: String, status: String, conclusion: String?, url: String?, steps: [Step],
            startedAt: String? = nil, completedAt: String? = nil
        ) {
            self.id = id
            self.name = name
            self.status = status
            self.conclusion = conclusion
            self.url = url
            self.steps = steps
            self.startedAt = startedAt
            self.completedAt = completedAt
        }
        public var failed: Bool { CIRuns.failed(status, conclusion) }
    }
    public struct Run: Codable, Sendable, Equatable {
        public var id: Int, title: String, workflow: String, status: String, conclusion: String?, event: String,
            url: String, createdAt: String
        /// The forge's count of the workflow's runs, the commit, which try this is; when this try began and last changed.
        public var number: Int?, sha: String?, attempt: Int?, startedAt: String?, updatedAt: String?
        public init(
            id: Int, title: String, workflow: String, status: String, conclusion: String?, event: String, url: String,
            createdAt: String,
            number: Int? = nil, sha: String? = nil, attempt: Int? = nil, startedAt: String? = nil,
            updatedAt: String? = nil
        ) {
            self.id = id
            self.title = title
            self.workflow = workflow
            self.status = status
            self.conclusion = conclusion
            self.event = event
            self.url = url
            self.createdAt = createdAt
            self.number = number
            self.sha = sha
            self.attempt = attempt
            self.startedAt = startedAt
            self.updatedAt = updatedAt
        }
        public var failed: Bool { CIRuns.failed(status, conclusion) }
        /// When this try began: `createdAt` stays at the first one, however much later a re-run comes.
        public var began: String { startedAt ?? createdAt }
        public var finished: Bool { status == "completed" }
        /// Seconds this try took, or has taken so far.
        public func seconds(now: Date = Date()) -> Double? {
            CIRuns.seconds(from: began, to: finished ? updatedAt : nil, now: now)
        }
        /// The commit's page on the forge, from the run's own: ".../actions/runs/1" → ".../commit/<sha>".
        public var commitURL: String? {
            guard let sha, let cut = url.range(of: "/actions/runs/") ?? url.range(of: "/-/pipelines/") else {
                return nil
            }
            return url[..<cut.lowerBound]
                + (cut.lowerBound < url.endIndex && url[cut].hasPrefix("/-/") ? "/-/commit/" : "/commit/") + sha
        }
        /// Seven characters, as git shows it.
        public var shortSHA: String? { sha.map { String($0.prefix(7)) } }
    }

    public static func date(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    /// From `from` to `to`, or to now for what is still going.
    public static func seconds(from: String?, to: String?, now: Date = Date()) -> Double? {
        guard let from, let start = date(from) else { return nil }
        guard let to else { return now.timeIntervalSince(start) }
        return date(to).map { $0.timeIntervalSince(start) }
    }
    /// The newest run of each workflow (runs come newest first): what the branch's CI says now.
    public static func latest(_ runs: [Run]) -> [Run] {
        var seen = Set<String>()
        return runs.filter { seen.insert($0.workflow).inserted }
    }

    /// A branch's CI in one mark, least to most pressing: of two sources (its runs, its PR's checks) the greater wins.
    public enum State: Int, Sendable, Comparable {
        case passed, running, waiting, failed
        public static func < (lhs: State, rhs: State) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    /// From the newest run of each workflow: one failed; else one waiting for someone's approval (a deploy to a protected
    /// environment, a fork's first run); else one not finished; else one that succeeded. Nil: no runs, or only skipped or
    /// cancelled ones (someone stopped it: nothing to fix).
    public static func state(_ runs: [Run]) -> State? {
        let now = latest(runs)
        if now.contains(where: { $0.failed && !["cancelled", "action_required"].contains($0.conclusion) }) {
            return .failed
        }
        if now.contains(where: { $0.status == "waiting" || $0.conclusion == "action_required" }) { return .waiting }
        if now.contains(where: { $0.status != "completed" }) { return .running }
        return now.contains { $0.conclusion == "success" } ? .passed : nil
    }
    /// A pull request's checks, which also count what runs outside the forge's CI (a deploy preview, a review bot).
    public static func state(_ checks: GitHub.PullRequest.Checks) -> State? {
        checks.failed > 0 ? .failed : checks.pending > 0 ? .running : checks.passed > 0 ? .passed : nil
    }
    /// A workflow you can start by hand (`on: workflow_dispatch`), with the inputs its form asks for.
    public struct Workflow: Codable, Sendable, Equatable {
        public struct Input: Codable, Sendable, Equatable {
            public var name: String, description: String, defaultValue: String, options: [String], required: Bool
            public init(name: String, description: String, defaultValue: String, options: [String], required: Bool) {
                self.name = name
                self.description = description
                self.defaultValue = defaultValue
                self.options = options
                self.required = required
            }
        }
        public var file: String, name: String, inputs: [Input]
        public init(file: String, name: String, inputs: [Input]) {
            self.file = file
            self.name = name
            self.inputs = inputs
        }
    }
}

extension CIRuns {
    /// The line (from 1) where a step begins in a job's readable log, which marks each with "▸ step".
    public static func line(ofStep step: String, in log: String) -> Int? {
        log.split(separator: "\n", omittingEmptySubsequences: false).firstIndex { $0 == "▸ " + step }.map { $0 + 1 }
    }
}

extension CIRuns.Step {
    /// Seconds it took, or has taken so far.
    public func seconds(now: Date = Date()) -> Double? {
        CIRuns.seconds(from: startedAt, to: status == "completed" ? completedAt : nil, now: now)
    }

    /// A step's name without what GitHub adds to it: "Run actions/checkout@11d5960" reads "checkout". A step named in
    /// its workflow stays as written.
    public var shortName: String {
        let post = name.hasPrefix("Post Run ")
        guard post || name.hasPrefix("Run ") else { return name }
        let rest = name.dropFirst(post ? "Post Run ".count : "Run ".count)
        let short = rest.wholeMatch(of: /[\w.-]+\/([\w.-]+)(?:\/\S*)?@\S+/).map { String($0.1) } ?? String(rest)
        return post ? "Post " + short : short
    }
}

extension CIRuns.Job {
    public func seconds(now: Date = Date()) -> Double? {
        CIRuns.seconds(from: startedAt, to: status == "completed" ? completedAt : nil, now: now)
    }
}

extension CIRuns {
    /// A job's steps as a list reads them: what failed or is running on its own, the rest folded by how it went.
    public enum StepRow: Equatable, Sendable {
        case one(Step), passed([Step]), skipped([Step]), upcoming([Step])
        public var steps: [Step] {
            switch self {
            case .one(let step): [step]
            case .passed(let steps), .skipped(let steps), .upcoming(let steps): steps
            }
        }
    }

    public static func rows(_ steps: [Step]) -> [StepRow] {
        let upcoming = steps.filter { !["completed", "in_progress"].contains($0.status) }
        let done = steps.filter { $0.status == "completed" && !$0.failed }
        let skipped = done.filter { ["skipped", "cancelled"].contains($0.conclusion) }
        let passed = done.filter { !["skipped", "cancelled"].contains($0.conclusion) }
        let ones = steps.filter { $0.failed || $0.status == "in_progress" }
        func fold(_ steps: [Step], _ row: ([Step]) -> StepRow) -> [StepRow] {
            steps.count > 1 ? [row(steps)] : steps.map(StepRow.one)
        }
        return fold(passed, StepRow.passed) + ones.map(StepRow.one) + fold(skipped, StepRow.skipped)
            + fold(upcoming, StepRow.upcoming)
    }
}

extension CIRuns {
    /// How long this workflow usually takes: the middle of its green runs, the newest five. Failed runs stop early and say
    /// nothing about it. Nil under three.
    public static func typicalSeconds(_ runs: [Run], workflow: String) -> Double? {
        let green = runs.filter { $0.workflow == workflow && $0.conclusion == "success" }.prefix(5).compactMap {
            $0.seconds()
        }.sorted()
        guard green.count >= 3 else { return nil }
        return green.count % 2 == 1 ? green[green.count / 2] : (green[green.count / 2 - 1] + green[green.count / 2]) / 2
    }

    /// A workflow's last dozen runs, oldest first, and the newest green one when the latest isn't.
    public struct History: Equatable, Sendable {
        public var runs: [Run], lastGreen: Run?, greenInARow: Int
    }

    /// Of the workflow that matters now: the one that failed, else the newest. Nil with one run: no history to show.
    public static func history(_ runs: [Run]) -> History? {
        let now = latest(runs)
        guard let workflow = (now.first(where: \.failed) ?? now.first)?.workflow else { return nil }
        let own = runs.filter { $0.workflow == workflow }
        guard own.count > 1 else { return nil }
        let row = own.prefix { $0.conclusion == "success" }.count
        return History(
            runs: own.prefix(12).reversed(), lastGreen: row > 0 ? nil : own.first { $0.conclusion == "success" },
            greenInARow: row)
    }
}

extension CIRuns.Report {
    /// Whether an earlier try broke the same way: then it's the code, not a fluke of the runner.
    public func failsLike(_ other: CIRuns.Report) -> Bool {
        func names(_ report: CIRuns.Report) -> Set<String> {
            Set(
                report.failures.map {
                    [$0.suite, $0.test, $0.test == nil ? $0.place : nil].compactMap { $0 }.joined(separator: ".")
                })
        }
        return !failures.isEmpty && names(self) == names(other)
    }
}
