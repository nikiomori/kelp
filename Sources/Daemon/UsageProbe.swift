import Foundation
import os
import Core
import Agents
import AgentData

/// Plan limits as the agents themselves show them in `/usage` (Claude Code, Grok, Antigravity, Kimi, Copilot, Cursor). A hidden copy of
/// the agent opens that screen now and then and quits: no tokens are spent and Kelp never touches their credentials.
extension AgentUsage {
    struct PlanProbe: Sendable {
        let agent: String, command: String, every: TimeInterval
        var ready: @Sendable (String) -> Bool = { _ in true }    // its prompt is drawn
        var shown: @Sendable (String) -> Bool = { _ in true }    // the usage screen has loaded
        let parse: @Sendable (String) -> [ClaudeLimits.Reading]
        var env: [String: String] = [:]          // extra launch env (e.g. Kimi's trust-this-run)
        var answersTrust = false                 // its "trust this folder?" has a default that trusts for this run only (Copilot)
        /// With these it prints the usage and exits, no terminal: nothing opens, so no session or prompt history is left (Claude's `-p`).
        var printArgs: [String] = []
    }
    struct PlanState {
        var readings: [ClaudeLimits.Reading] = []
        var at: Date?, readAt: Date?
        var running = false
        /// Limits a session saw run out that `/usage` doesn't show (Cursor's Free plan reads 0% after its last request): held
        /// over the probe's readings until the probe's reset date for that limit moves on.
        var hits: [ClaudeLimits.Reading] = []

        /// The probe's `readings`, with each hit still in its cycle over the reading of its kind.
        mutating func read(_ fresh: [ClaudeLimits.Reading]) {
            hits.removeAll { h in fresh.contains { $0.kind == h.kind && $0.resets != h.resets } }
            readings = fresh
            for i in readings.indices {
                if let hit = hits.first(where: { $0.kind == readings[i].kind }) { readings[i].percent = max(readings[i].percent, hit.percent) }
            }
            readAt = Date()
        }
    }

    /// A session printed that `agent`'s plan ran out.
    func recordPlanHit(_ agent: String, _ r: [ClaudeLimits.Reading]) {
        plans.withLock { plans in
            var s = plans[agent] ?? PlanState()
            // No date in what it printed: the cycle /usage last showed.
            var r = r
            for i in r.indices where r[i].resets == nil { r[i].resets = s.readings.first { $0.kind == r[i].kind }?.resets }
            s.hits = r + s.hits.filter { h in !r.contains { $0.kind == h.kind } }
            s.read(s.readings.isEmpty ? r : s.readings)
            plans[agent] = s
        }
    }

    static let planProbes = [
        // Opened in a terminal, every reading was a session of its own in Claude's /resume and a "/usage" in its prompt history.
        PlanProbe(agent: "claude", command: "claude", every: 600, parse: ClaudeLimits.parseUsage,
                  printArgs: ["-p", "/usage", "--no-session-persistence", "--strict-mcp-config"]),   // no MCP server starts for it
        // With any hook of the user's own, Grok asks "Do you trust the contents of this directory?" in every folder; this
        // run alone does without the question, and nothing is written to its trusted_folders.toml.
        PlanProbe(agent: "grok", command: "grok", every: 1800, ready: { $0.contains("Ctrl+x:shortcuts") },
                  shown: { $0.contains("Weekly limit") && $0.contains("Resets") }, parse: ClaudeLimits.parseGrokUsage,
                  env: ["GROK_FOLDER_TRUST": "0"]),
        // Its /usage typed in a terminal went into its prompt history every time.
        PlanProbe(agent: "antigravity", command: "agy", every: 1800, parse: { ClaudeLimits.parseAntigravityUsage($0) },
                  printArgs: ["-p", "/usage"]),
        // Trust for this process only: the probe has no one to answer "Trust this folder?".
        PlanProbe(agent: "kimi", command: "kimi", every: 1800,
                  ready: { $0.contains("│ >") || $0.contains("context:") },
                  shown: { $0.contains("Plan usage") }, parse: ClaudeLimits.parseKimiUsage,
                  env: ["KIMI_CODE_TRUST_WORKSPACE": "1"]),
        // "Plan ■■■■ 2% used 5 / 200 AIC". Its folder question is answered with Enter: "1. Yes", for this session only.
        PlanProbe(agent: "copilot", command: "copilot", every: 1800, ready: { $0.contains("/ commands") },
                  shown: { $0.contains("Plan") && $0.contains("% used") }, parse: ClaudeLimits.parseCopilotUsage, answersTrust: true),
        PlanProbe(agent: "cursor", command: "cursor-agent", every: 1800, ready: { $0.contains("build anything") },
                  shown: { $0.contains("Included") && $0.contains("% used") }, parse: ClaudeLimits.parseCursorUsage)
    ]

    /// Settings › Show plan limits.
    var readsPlans: Bool { (settings["usage.readPlans"] ?? settings["usage.readClaudePlan"])?.bool != false }

    func refreshPlansIfStale() {
        guard readsPlans else { return }
        for probe in Self.planProbes {
            let start: Bool = plans.withLock { plans in
                let s = plans[probe.agent] ?? PlanState()
                guard !s.running, Date().timeIntervalSince(s.at ?? .distantPast) > probe.every else { return false }
                plans[probe.agent, default: PlanState()].running = true; return true
            }
            guard start else { continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                var readings: [ClaudeLimits.Reading] = []
                if let path = try? LoginPath.resolve(probe.command) {
                    var screen = ""
                    if !probe.printArgs.isEmpty {
                        screen = Sessions.run([path] + probe.printArgs, path: LoginPath.value, timeout: 30) ?? ""
                        readings = probe.parse(screen)
                    } else if let cwd = probeDir {
                        for argv in probeArgv(probe.agent, path) {
                            (readings, screen) = Self.probe(probe, argv: argv, cwd: cwd)
                            if !readings.isEmpty { break }
                        }
                    }
                    // What a failed probe saw, for whoever fixes the parser when an agent changes its screen.
                    if readings.isEmpty, (try? Paths.ensure(root.appendingPathComponent("probe"))) != nil {
                        try? screen.write(to: root.appendingPathComponent("probe/\(probe.agent).txt"), atomically: true, encoding: .utf8)
                    }
                }
                plans.withLock { [readings] plans in
                    if !readings.isEmpty { plans[probe.agent]?.read(readings) }
                    // A failed probe retries in 2 minutes rather than waiting a whole round.
                    plans[probe.agent]?.at = readings.isEmpty ? Date().addingTimeInterval(120 - probe.every) : Date()
                    plans[probe.agent]?.running = false
                }
            }
        }
    }

    /// A turn just ended, so the agent's usage moved: read its plan half a minute from now instead of at the next round
    /// (up to 10 minutes late for Claude). The UI's next `usage.get` starts the read.
    func planUsed(_ agent: String) {
        if agent == "codex" { codexLive.withLock { $0.at = min($0.at, Date().addingTimeInterval(30 - Self.codexEvery)) } }
        guard let p = Self.planProbes.first(where: { $0.agent == agent }) else { return }
        plans.withLock { plans in
            guard let at = plans[agent]?.at else { return }
            plans[agent]?.at = min(at, Date().addingTimeInterval(30 - p.every))
        }
    }

    static let codexEvery: TimeInterval = 600

    /// Codex's limits as its /status shows them, asked of `codex app-server` every 10 minutes (half a minute after a
    /// turn): no tokens, and no TUI, so no startup question (trust this folder? these hooks?) stands in the way. Never
    /// Codex's `/usage`: there it spends a limit reset.
    /// Limit: the default account's only (CODEX_HOME); account profiles keep what their sessions logged.
    func refreshCodexIfStale() {
        guard readsPlans else { return }
        let start: Bool = codexLive.withLock { s in
            guard !s.running, Date().timeIntervalSince(s.at) > Self.codexEvery else { return false }
            s.running = true; return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let l = (try? LoginPath.resolve("codex")).flatMap(Self.codexLimits)
            self?.codexLive.withLock { s in
                if let l { s.limits = l }
                s.at = Date(); s.running = false
            }
        }
    }

    /// One `account/rateLimits/read`. The app server quits as soon as its input closes, before answering, so it gets a
    /// terminal like the /usage probes and is stopped once it has answered.
    static func codexLimits(path: String) -> CodexLimits? {
        let out = ScreenBuffer()
        let pty: PTY
        do { pty = try PTY(argv: [path, "app-server"], cwd: NSTemporaryDirectory(), env: ["PATH": LoginPath.value]) }
        catch { Log.session.error("codex app-server didn't start: \(error)"); return nil }
        pty.onOutput = { out.append($0) }
        pty.start()
        defer { pty.terminate() }
        let ask = [#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"kelp","version":"1"}}}"#, #"{"method":"initialized"}"#,
                   #"{"id":2,"method":"account/rateLimits/read"}"#]
        pty.write(Data((ask.joined(separator: "\n") + "\n").utf8))
        var answer: [String: Any]?
        _ = out.wait(20) { text in   // the terminal echoes the questions back: only an answer has a result or an error
            answer = text.split(whereSeparator: \.isNewline).lazy.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .first { $0["id"] as? Int == 2 && ($0["result"] != nil || $0["error"] != nil) }
            return answer != nil
        }
        let l = CodexUsage.limits(rateLimits: (answer?["result"] as? [String: Any])?["rateLimits"], at: Date())
        if l == nil { Log.session.error("codex app-server gave no limits: \(answer.map { "\($0)" } ?? "no answer in 20 s")") }
        return l
    }

    /// Kelp's own folder, with no agent config in it: nobody watches the hidden copy, so no project's hooks or MCP servers
    /// may come in unseen. Each agent trusts it for the run (Grok's and Kimi's env, Copilot's Enter, Cursor's --trust).
    private var probeDir: String? {
        let d = root.appendingPathComponent("probe")
        return (try? Paths.ensure(d)).map { d.path }
    }

    /// Always the same session, so a reading leaves no session of its own in the agent's list (Copilot and Cursor kept one
    /// per reading). Kimi keeps none for a launch that only looked.
    private func probeArgv(_ agent: String, _ path: String) -> [[String]] {
        guard ["grok", "copilot", "cursor"].contains(agent) else { return [[path]] }
        let file = root.appendingPathComponent("probe/\(agent)-session")
        let id = (try? String(contentsOf: file, encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? UUID().uuidString.lowercased()
        Log.session.attempt("keeping the usage probe's session id") { try id.write(to: file, atomically: true, encoding: .utf8) }
        return switch agent {
        // Resume, then same id, then a fresh one if another probe still holds the lock ("already in use").
        case "grok": [[path, "--resume", id], [path, "--session-id", id], [path, "--session-id", UUID().uuidString.lowercased()]]
        case "copilot": [[path, "--session-id", id], [path]]           // resumes that session, or starts it under that id
        default: [[path, "--trust", "--resume", id], [path, "--trust"]]  // Cursor: an id it doesn't know becomes the new chat's
        }
    }

    static func probe(_ p: PlanProbe, argv: [String], cwd: String) -> ([ClaudeLimits.Reading], String) {
        let screen = ScreenBuffer()
        let pty: PTY
        let env = ["PATH": LoginPath.value].merging(p.env) { _, n in n }
        do { pty = try PTY(argv: argv, cwd: cwd, env: env, cols: 120, rows: 80) }
        catch { Log.session.error("the usage probe for \(argv.first ?? "", privacy: .public) didn't start: \(error)"); return ([], "") }
        pty.onOutput = { screen.append($0) }
        pty.start()
        defer { pty.terminate() }
        var trusted = false
        if p.answersTrust {
            _ = screen.wait(15) { p.ready($0) || StartupQuestion.trustAsked($0) }
            if !p.ready(StatusDetector.stripANSI(screen.text)), StartupQuestion.trustAsked(StatusDetector.stripANSI(String(screen.text.suffix(3000)))) {
                pty.write(Data("\r".utf8))
                trusted = true
            }
        }
        // Ready: the prompt is drawn and output went quiet (or it failed and said so).
        guard screen.wait(20, until: { (p.ready($0) && screen.quietFor > 1) || $0.contains("Error:") }),
              p.ready(StatusDetector.stripANSI(screen.text)) else { return ([], StatusDetector.stripANSI(screen.text)) }
        // Nobody watches this copy: a question on screen (trust this folder? use the project's new MCP servers?) is left
        // unanswered and the probe gives up. Typing /usage and Enter there would pick its default, usually "Yes".
        let drawn = StatusDetector.stripANSI(String(screen.text.suffix(3000)))
        if !trusted, StartupQuestion.trustAsked(drawn) || StartupQuestion.menuOpen(drawn) { return ([], drawn) }
        // Tips that say "esc to dismiss" steal the first keystrokes; clear them before typing /usage.
        if drawn.localizedCaseInsensitiveContains("esc to dismiss") {
            pty.write(Data("\u{1B}".utf8))
            _ = screen.wait(5) { !StatusDetector.stripANSI($0).localizedCaseInsensitiveContains("esc to dismiss") && screen.quietFor > 0.5 }
        }
        pty.write(Data("/usage".utf8))
        Thread.sleep(forTimeInterval: 0.6)
        pty.write(Data("\r".utf8))
        // Wait until the screen has the numbers; don't insist on quiet — Claude/Antigravity keep refreshing while open.
        _ = screen.wait(25) { p.shown($0) }
        _ = screen.wait(2) { _ in screen.quietFor > 1.0 }
        // Parse before Esc: many TUIs put /usage on an alt screen that Esc discards.
        let text = StatusDetector.stripANSI(screen.text).replacingOccurrences(of: "\r", with: "\n")
        let readings = p.parse(text)
        pty.write(Data("\u{1B}".utf8))
        return (readings, text)
    }
}

/// Output collected from a probe's PTY.
private final class ScreenBuffer: Sendable {
    private let state = OSAllocatedUnfairLock<(data: Data, last: Date)>(initialState: (Data(), Date()))
    func append(_ d: Data) { state.withLock { $0.data.append(d); $0.last = Date() } }
    // swiftlint:disable:next optional_data_string_conversion
    var text: String { String(decoding: state.withLock { $0 }.data, as: UTF8.self) }   // lossy on purpose: TUI output
    var quietFor: TimeInterval { Date().timeIntervalSince(state.withLock { $0 }.last) }
    func wait(_ seconds: TimeInterval, until ok: (String) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if ok(StatusDetector.stripANSI(text)) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
