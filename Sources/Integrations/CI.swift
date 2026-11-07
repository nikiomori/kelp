import Core
import Foundation
import GitKit

/// CI runs of one branch: GitHub Actions (`gh run`) and GitLab pipelines (`glab api`), the values in Core.
extension CIRuns {
    // MARK: GitHub

    public static func runs(cwd: String, branch: String) throws -> [Run] {
        if GitLab.isGitLab(cwd: cwd) { return try gitlabRuns(cwd: cwd, branch: branch) }
        struct RawRun: Decodable {
            var databaseId: Int, displayTitle: String, workflowName: String?, name: String?, status: String,
                conclusion: String?
            var event: String, url: String, createdAt: String
            var number: Int?, attempt: Int?, headSha: String?, startedAt: String?, updatedAt: String?
        }
        let fields =
            "databaseId,displayTitle,workflowName,name,status,conclusion,event,url,createdAt,number,attempt,headSha,startedAt,updatedAt"
        let data = try GitHub.gh(["run", "list", "--branch", branch, "-L", "20", "--json", fields], cwd: cwd)
        return try JSONDecoder().decode([RawRun].self, from: data).map {
            Run(
                id: $0.databaseId, title: $0.displayTitle, workflow: $0.workflowName ?? $0.name ?? "",
                status: $0.status,
                conclusion: $0.conclusion.flatMap { $0.isEmpty ? nil : $0 }, event: $0.event, url: $0.url,
                createdAt: $0.createdAt,
                number: $0.number, sha: $0.headSha, attempt: $0.attempt, startedAt: moment($0.startedAt),
                updatedAt: moment($0.updatedAt))
        }
    }

    public static func jobs(cwd: String, run: Int) throws -> [Job] {
        if GitLab.isGitLab(cwd: cwd) { return try gitlabJobs(cwd: cwd, pipeline: run) }
        struct RawStep: Decodable {
            var name: String, status: String, conclusion: String?, number: Int?, startedAt: String?,
                completedAt: String?
        }
        struct RawJob: Decodable {
            var databaseId: Int, name: String, status: String, conclusion: String?, url: String?, steps: [RawStep]?
            var startedAt: String?, completedAt: String?
        }
        struct RunView: Decodable { var jobs: [RawJob] }
        let view = try JSONDecoder().decode(
            RunView.self, from: GitHub.gh(["run", "view", String(run), "--json", "jobs"], cwd: cwd))
        return view.jobs.map { job in
            Job(
                id: job.databaseId, name: job.name, status: job.status,
                conclusion: job.conclusion.flatMap { $0.isEmpty ? nil : $0 }, url: job.url,
                steps: (job.steps ?? []).map {
                    Step(
                        name: $0.name, status: $0.status, conclusion: $0.conclusion.flatMap { $0.isEmpty ? nil : $0 },
                        number: $0.number,
                        startedAt: moment($0.startedAt), completedAt: moment($0.completedAt))
                }, startedAt: moment(job.startedAt), completedAt: moment(job.completedAt))
        }
    }

    /// GitHub says "0001-01-01T00:00:00Z" of a time that hasn't come yet.
    private static func moment(_ iso: String?) -> String? { iso?.hasPrefix("0001") == true ? nil : iso }

    /// The failed steps' output of a job (the whole log if nothing failed), its last ~12 KB.
    public static func log(cwd: String, job: Int) throws -> String { GitHub.tail(try failedText(cwd: cwd, job: job)) }

    /// Every step of a job.
    public static func fullLog(cwd: String, job: Int) throws -> String {
        if GitLab.isGitLab(cwd: cwd) {
            return wholeLog(trace: try GitLab.api("projects/:id/jobs/\(job)/trace", cwd: cwd))
        }
        return readable(
            String(decoding: try GitHub.gh(["run", "view", "--job", String(job), "--log"], cwd: cwd), as: UTF8.self))
    }

    /// What broke in a job, read from its log before the tail is cut.
    public static func report(cwd: String, job: Int) throws -> Report {
        located(report(log: try failedText(cwd: cwd, job: job)), cwd: cwd)
    }

    /// What broke in a run; `attempt`: a run's earlier try, which is how a failure that came back can be told from a fluke.
    public static func report(cwd: String, run: Int, attempt: Int?) throws -> Report {
        let args = ["run", "view", String(run)] + (attempt.map { ["--attempt", String($0)] } ?? []) + ["--log-failed"]
        return located(report(log: readable(String(decoding: try GitHub.gh(args, cwd: cwd), as: UTF8.self))), cwd: cwd)
    }

    private static func failedText(cwd: String, job: Int) throws -> String {
        if GitLab.isGitLab(cwd: cwd) {
            return wholeLog(trace: try GitLab.api("projects/:id/jobs/\(job)/trace", cwd: cwd))
        }
        let failed =
            (try? GitHub.gh(["run", "view", "--job", String(job), "--log-failed"], cwd: cwd)).flatMap {
                String(bytes: $0, encoding: .utf8)
            } ?? ""
        if !failed.isEmpty { return readable(failed) }
        return readable(
            String(bytes: try GitHub.gh(["run", "view", "--job", String(job), "--log"], cwd: cwd), encoding: .utf8)
                ?? "")
    }

    private static func wholeLog(trace: Data) -> String { readable(String(bytes: trace, encoding: .utf8) ?? "") }

    /// gh writes every log line as "job⇥step⇥timestamp text": keep the text, with a "▸ step" line where each step
    /// begins, and drop terminal color codes and the runner's ##[group] markers.
    static func readable(_ log: String) -> String {
        var out: [String] = [], step: Substring?
        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = line
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 {
                if parts[1] != step {
                    step = parts[1]
                    out.append((out.isEmpty ? "" : "\n") + "▸ " + parts[1])
                }
                text = parts[2].replacing(/^\x{FEFF}?\d{4}-\d\d-\d\dT[\d:.]+Z ?/, with: "")
            }
            if text == "##[endgroup]" { continue }
            out.append(
                String(
                    text.replacing(/(\x{1B}|\^\[)\[[0-9;]*[A-Za-z]/, with: "").replacing(/^##\[group\]/, with: "")
                        .replacing(/^##\[error\]/, with: "Error: ").replacing(/^##\[warning\]/, with: "Warning: ")))
        }
        return out.joined(separator: "\n")
    }

    public static func rerunFailed(cwd: String, run: Int) throws {
        if GitLab.isGitLab(cwd: cwd) {
            _ = try GitLab.api("projects/:id/pipelines/\(run)/retry", cwd: cwd, method: "POST")
            return
        }
        try GitHub.gh(["run", "rerun", String(run), "--failed"], cwd: cwd)
    }

    /// Limit: GitLab's retry takes the failed jobs only.
    public static func rerunAll(cwd: String, run: Int) throws {
        if GitLab.isGitLab(cwd: cwd) { return try rerunFailed(cwd: cwd, run: run) }
        try GitHub.gh(["run", "rerun", String(run)], cwd: cwd)
    }

    public static func rerunJob(cwd: String, job: Int) throws {
        if GitLab.isGitLab(cwd: cwd) {
            _ = try GitLab.api("projects/:id/jobs/\(job)/retry", cwd: cwd, method: "POST")
            return
        }
        try GitHub.gh(["run", "rerun", "--job", String(job)], cwd: cwd)
    }

    public static func cancel(cwd: String, run: Int) throws {
        if GitLab.isGitLab(cwd: cwd) {
            _ = try GitLab.api("projects/:id/pipelines/\(run)/cancel", cwd: cwd, method: "POST")
            return
        }
        try GitHub.gh(["run", "cancel", String(run)], cwd: cwd)
    }

    /// `workflow` is a file name from the repository: after `--`, so one named "-F….yml" is a name, not an option.
    public static func dispatch(cwd: String, workflow: String, branch: String, inputs: [String: String]) throws {
        let fields = inputs.sorted { $0.key < $1.key }.flatMap { ["-f", "\($0.key)=\($0.value)"] }
        try GitHub.gh(["workflow", "run", "--ref", branch] + fields + ["--", workflow], cwd: cwd)
    }

    /// `.github/workflows/*.yml` that can be started by hand, read just far enough for their inputs.
    public static func dispatchable(repo: String) -> [Workflow] {
        let dir = URL(fileURLWithPath: repo).appendingPathComponent(".github/workflows")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter {
            $0.hasSuffix(".yml") || $0.hasSuffix(".yaml")
        }.sorted()
        return files.compactMap { file in
            guard let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else {
                return nil
            }
            return parseWorkflow(text, file: file)
        }
    }

    /// The `workflow_dispatch:` inputs of a workflow file. Limit: an indentation reader, not YAML; flow-style maps are missed.
    static func parseWorkflow(_ text: String, file: String) -> Workflow? {
        let lines = text.components(separatedBy: "\n")
        guard
            let dispatchLine = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("workflow_dispatch")
            })
        else { return nil }
        let name = lines.first { $0.hasPrefix("name:") }.map { unquote(String($0.dropFirst(5))) } ?? file
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        let base = indent(lines[dispatchLine])
        var inputs: [Workflow.Input] = [], index = dispatchLine + 1, inputIndent: Int?
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            if indent(line) <= base { break }
            if trimmed == "inputs:" {
                index += 1
                continue
            }
            if inputIndent == nil || indent(line) == inputIndent, trimmed.hasSuffix(":"), !trimmed.contains(" ") {
                inputIndent = indent(line)
                inputs.append(
                    .init(
                        name: String(trimmed.dropLast()), description: "", defaultValue: "", options: [],
                        required: false))
            } else if var last = inputs.popLast() {
                if trimmed.hasPrefix("description:") { last.description = unquote(String(trimmed.dropFirst(12))) }
                if trimmed.hasPrefix("default:") { last.defaultValue = unquote(String(trimmed.dropFirst(8))) }
                if trimmed.hasPrefix("required:") { last.required = trimmed.hasSuffix("true") }
                if trimmed.hasPrefix("- ") { last.options.append(unquote(String(trimmed.dropFirst(2)))) }
                inputs.append(last)
            }
            index += 1
        }
        return Workflow(file: file, name: name, inputs: inputs)
    }

    static func unquote(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    // MARK: GitLab

    static func gitlabRuns(cwd: String, branch: String) throws -> [Run] {
        struct RawPipeline: Decodable {
            var id: Int, status: String, source: String?, web_url: String, created_at: String, ref: String
            var iid: Int?, sha: String?, updated_at: String?
        }
        let ref = GitLab.queryValue(branch)
        return try JSONDecoder().decode(
            [RawPipeline].self, from: GitLab.api("projects/:id/pipelines?ref=\(ref)&per_page=20", cwd: cwd)
        ).map {
            let (status, conclusion) = gitlabState($0.status)
            return Run(
                id: $0.id, title: "Pipeline #\($0.id)", workflow: $0.ref, status: status, conclusion: conclusion,
                event: $0.source ?? "",
                url: $0.web_url, createdAt: $0.created_at, number: $0.iid, sha: $0.sha, updatedAt: $0.updated_at)
        }
    }

    static func gitlabJobs(cwd: String, pipeline: Int) throws -> [Job] {
        struct RawGitLabJob: Decodable {
            var id: Int, name: String, status: String, web_url: String?, stage: String?, started_at: String?,
                finished_at: String?
        }
        return try JSONDecoder().decode(
            [RawGitLabJob].self, from: GitLab.api("projects/:id/pipelines/\(pipeline)/jobs?per_page=100", cwd: cwd)
        ).map {
            let (status, conclusion) = gitlabState($0.status)
            return Job(
                id: $0.id, name: [$0.stage, $0.name].compactMap { $0 }.joined(separator: " · "), status: status,
                conclusion: conclusion, url: $0.web_url, steps: [],
                startedAt: $0.started_at, completedAt: $0.finished_at)
        }
    }

    /// GitLab's states in GitHub's two fields.
    static func gitlabState(_ status: String) -> (String, String?) {
        switch status {
        case "success": ("completed", "success")
        case "failed": ("completed", "failure")
        case "canceled": ("completed", "cancelled")
        case "skipped": ("completed", "skipped")
        case "manual": ("waiting", nil)
        default: ("in_progress", nil)
        }
    }
}
