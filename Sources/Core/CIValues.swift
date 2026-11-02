import Foundation

/// CI runs of one branch, the same for GitHub Actions (`gh run`) and GitLab pipelines (`glab api`).
public enum CIRuns {
    /// Finished without success (failed, timed out, cancelled…).
    public static func failed(_ status: String, _ conclusion: String?) -> Bool {
        status == "completed" && !["success", "skipped", "neutral", nil].contains(conclusion)
    }
    public struct Step: Codable, Sendable, Equatable {
        public var name: String; public var status: String; public var conclusion: String?
        /// Its place in the job, which a link to the step names.
        public var number: Int?, startedAt: String?, completedAt: String?
        public init(name: String, status: String, conclusion: String?, number: Int? = nil, startedAt: String? = nil,
                    completedAt: String? = nil) {
            self.name = name; self.status = status; self.conclusion = conclusion
            self.number = number; self.startedAt = startedAt; self.completedAt = completedAt
        }
        public var failed: Bool { CIRuns.failed(status, conclusion) }
    }
    public struct Job: Codable, Sendable, Equatable {
        public var id: Int, name: String, status: String, conclusion: String?, url: String?
        public var steps: [Step]
        public var startedAt: String?, completedAt: String?
        public init(id: Int, name: String, status: String, conclusion: String?, url: String?, steps: [Step],
                    startedAt: String? = nil, completedAt: String? = nil) {
            self.id = id; self.name = name; self.status = status; self.conclusion = conclusion; self.url = url; self.steps = steps
            self.startedAt = startedAt; self.completedAt = completedAt
        }
        public var failed: Bool { CIRuns.failed(status, conclusion) }
    }
    public struct Run: Codable, Sendable, Equatable {
        public var id: Int, title: String, workflow: String, status: String, conclusion: String?, event: String, url: String, createdAt: String
        /// The forge's count of the workflow's runs, the commit, which try this is; when this try began and last changed.
        public var number: Int?, sha: String?, attempt: Int?, startedAt: String?, updatedAt: String?
        public init(id: Int, title: String, workflow: String, status: String, conclusion: String?, event: String, url: String, createdAt: String,
                    number: Int? = nil, sha: String? = nil, attempt: Int? = nil, startedAt: String? = nil, updatedAt: String? = nil) {
            self.id = id; self.title = title; self.workflow = workflow; self.status = status; self.conclusion = conclusion
            self.event = event; self.url = url; self.createdAt = createdAt
            self.number = number; self.sha = sha; self.attempt = attempt; self.startedAt = startedAt; self.updatedAt = updatedAt
        }
        public var failed: Bool { CIRuns.failed(status, conclusion) }
        /// When this try began: `createdAt` stays at the first one, however much later a re-run comes.
        public var began: String { startedAt ?? createdAt }
        public var finished: Bool { status == "completed" }
        /// Seconds this try took, or has taken so far.
        public func seconds(now: Date = Date()) -> Double? { CIRuns.seconds(from: began, to: finished ? updatedAt : nil, now: now) }
        /// Seven characters, as git shows it.
        public var shortSHA: String? { sha.map { String($0.prefix(7)) } }
    }

    public static func date(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
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
        public static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
    }
    /// From the newest run of each workflow: one failed; else one waiting for someone's approval (a deploy to a protected
    /// environment, a fork's first run); else one not finished; else one that succeeded. Nil: no runs, or only skipped or
    /// cancelled ones (someone stopped it: nothing to fix).
    public static func state(_ runs: [Run]) -> State? {
        let now = latest(runs)
        if now.contains(where: { $0.failed && !["cancelled", "action_required"].contains($0.conclusion) }) { return .failed }
        if now.contains(where: { $0.status == "waiting" || $0.conclusion == "action_required" }) { return .waiting }
        if now.contains(where: { $0.status != "completed" }) { return .running }
        return now.contains { $0.conclusion == "success" } ? .passed : nil
    }
    /// A pull request's checks, which also count what runs outside the forge's CI (a deploy preview, a review bot).
    public static func state(_ c: GitHub.PullRequest.Checks) -> State? {
        c.failed > 0 ? .failed : c.pending > 0 ? .running : c.passed > 0 ? .passed : nil
    }
    /// A workflow you can start by hand (`on: workflow_dispatch`), with the inputs its form asks for.
    public struct Workflow: Codable, Sendable, Equatable {
        public struct Input: Codable, Sendable, Equatable {
            public var name: String, description: String, defaultValue: String, options: [String], required: Bool
            public init(name: String, description: String, defaultValue: String, options: [String], required: Bool) {
                self.name = name; self.description = description; self.defaultValue = defaultValue; self.options = options; self.required = required
            }
        }
        public var file: String, name: String, inputs: [Input]
        public init(file: String, name: String, inputs: [Input]) { self.file = file; self.name = name; self.inputs = inputs }
    }
}
