import Foundation
import os
import Core
import Agents
import GitKit
import AgentData

/// Plan limits as the agents themselves show them in `/usage` (Claude Code, Grok Build, Antigravity). A hidden copy of
/// the agent opens that screen now and then and quits: no tokens are spent and Kelp never touches their credentials.
extension AgentUsage {
    struct PlanProbe: Sendable {
        let agent: String, command: String, every: TimeInterval
        let ready: @Sendable (String) -> Bool    // its prompt is drawn
        let shown: @Sendable (String) -> Bool    // the usage screen has loaded
        let parse: @Sendable (String) -> [ClaudeLimits.Reading]
    }
    struct PlanState { var readings: [ClaudeLimits.Reading] = []; var at: Date?; var running = false; var readAt: Date? }

    static let planProbes = [
        PlanProbe(agent: "claude", command: "claude", every: 600, ready: { $0.contains("❯") },
                  shown: { $0.contains("Current week") && $0.contains("% used") }, parse: ClaudeLimits.parseUsageScreen),
        PlanProbe(agent: "grok", command: "grok", every: 1800, ready: { $0.contains("Ctrl+x:shortcuts") },
                  shown: { $0.contains("Weekly limit") && $0.contains("Resets") }, parse: ClaudeLimits.parseGrokUsage),
        PlanProbe(agent: "antigravity", command: "agy", every: 1800, ready: { $0.contains("for shortcuts") },
                  shown: { $0.contains("Weekly Limit Remaining") && $0.contains("%") }, parse: ClaudeLimits.parseAntigravityUsage)
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
                if let path = try? LoginPath.resolve(probe.command), let cwd = probeDir(probe.agent) {
                    var screen = ""
                    for argv in probeArgv(probe.agent, path) {
                        (readings, screen) = Self.probe(probe, argv: argv, cwd: cwd)
                        if !readings.isEmpty { break }
                    }
                    // What a failed probe saw, for whoever fixes the parser when an agent changes its screen.
                    if readings.isEmpty, (try? Paths.ensure(root.appendingPathComponent("probe"))) != nil {
                        try? screen.write(to: root.appendingPathComponent("probe/\(probe.agent).txt"), atomically: true, encoding: .utf8)
                    }
                }
                plans.withLock { [readings] plans in
                    if !readings.isEmpty { plans[probe.agent]?.readings = readings; plans[probe.agent]?.readAt = Date() }
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
        return CodexUsage.limits(rateLimits: (answer?["result"] as? [String: Any])?["rateLimits"], at: Date())
    }

    /// A folder the agent already works in, so it won't ask whether to trust it. Grok doesn't ask, but keeps a session
    /// per launch: it gets Kelp's own folder and always the same session, so its history doesn't fill up.
    private func probeDir(_ agent: String) -> String? {
        if agent == "grok" {
            let d = root.appendingPathComponent("probe"); try? Paths.ensure(d); return d.path
        }
        let used = ((try? store.sessions()) ?? []).filter { $0.agent == agent }.sorted { $0.createdAt > $1.createdAt }.map(\.cwd)
        let trusted = agent == "antigravity" ? Self.antigravityTrusted() : agent == "claude" ? Self.claudeTrusted() : []
        let worktrees = (try? store.worktrees()) ?? []
        return Self.probeFolder(used: used, trusted: trusted, remoteRoot: root.appendingPathComponent("remote").path) { dir in
            guard FileManager.default.fileExists(atPath: dir), RemoteHost.of(dir) == nil else { return false }
            let w = worktrees.first { AgentTrust.normal($0.path) == AgentTrust.normal(dir) }
            return Self.quietFolder(dir, base: w.flatMap { try? store.repo($0.repoId)?.baseBranch })
        }
    }

    /// Nobody watches the hidden copy, so it only opens where the project's agent config (hooks, MCP servers) can't have
    /// come in unseen: a Kelp workspace whose config matches its base branch (the check a launch makes before answering
    /// trust), or any other folder with no agent config at all.
    static func quietFolder(_ dir: String, base: String?) -> Bool {
        if let base { return !AgentConfig.changed(dir, base: base) }
        return !AgentConfig.files.contains { FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent($0)) }
    }

    /// Where the hidden copy of an agent opens: a folder it already trusts, or it stops at its trust question and `/usage`
    /// never shows. Folders of the agent's recent sessions come first; a remote project's local folder never counts (its
    /// sessions run on the host, and the folder here holds nothing). With no trust list to go by, recent folders do.
    /// A trusted folder Kelp never worked in is skipped where macOS asks first (Documents, Desktop…): even checking that
    /// it exists would pop "Kelp would like to access…" out of nowhere.
    static func probeFolder(used: [String], trusted: [String], remoteRoot: String, home: String = NSHomeDirectory(),
                            usable: (String) -> Bool) -> String? {
        let local = used.filter { !$0.hasPrefix(remoteRoot + "/") && $0 != remoteRoot }
        let ordered = trusted.isEmpty ? local : local.filter(trusted.contains) + trusted.filter { !asksFirst($0, home: home) }.sorted()
        return ordered.first(where: usable)
    }

    /// In a place macOS guards under Privacy › Files and Folders.
    static func asksFirst(_ dir: String, home: String) -> Bool {
        dir.hasPrefix("/Volumes/") || ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .contains { dir == "\(home)/\($0)" || dir.hasPrefix("\(home)/\($0)/") }
    }

    /// Folders the user trusted in Claude Code (read only).
    private static func claudeTrusted() -> [String] {
        AgentTrust.trustedFolders(agent: "claude", env: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
    }

    private func probeArgv(_ agent: String, _ path: String) -> [[String]] {
        guard agent == "grok" else { return [[path]] }
        let file = root.appendingPathComponent("probe/grok-session")
        let id = (try? String(contentsOf: file, encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? UUID().uuidString.lowercased()
        try? id.write(to: file, atomically: true, encoding: .utf8)
        return [[path, "--resume", id], [path, "--session-id", id]]   // the first run creates it
    }

    /// Folders the user trusted in Antigravity (read only).
    private static func antigravityTrusted() -> [String] {
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return o["trustedWorkspaces"] as? [String] ?? []
    }

    static func probe(_ p: PlanProbe, argv: [String], cwd: String) -> ([ClaudeLimits.Reading], String) {
        let screen = ScreenBuffer()
        let pty: PTY
        do { pty = try PTY(argv: argv, cwd: cwd, env: ["PATH": LoginPath.value], cols: 120, rows: 80) }
        catch { Log.session.error("the usage probe for \(argv.first ?? "", privacy: .public) didn't start: \(error)"); return ([], "") }
        pty.onOutput = { screen.append($0) }
        pty.start()
        defer { pty.terminate() }
        // Ready: the prompt is drawn and output went quiet (or it failed and said so).
        guard screen.wait(20, until: { (p.ready($0) && screen.quietFor > 1) || $0.contains("Error:") }),
              p.ready(StatusDetector.stripANSI(screen.text)) else { return ([], StatusDetector.stripANSI(screen.text)) }
        // Nobody watches this copy: a question on screen (trust this folder? use the project's new MCP servers?) is left
        // unanswered and the probe gives up. Typing /usage and Enter there would pick its default, usually "Yes".
        let drawn = StatusDetector.stripANSI(String(screen.text.suffix(3000)))
        if StartupQuestion.trustAsked(drawn) || StartupQuestion.menuOpen(drawn) { return ([], drawn) }
        pty.write(Data("/usage".utf8)); Thread.sleep(forTimeInterval: 0.6); pty.write(Data("\r".utf8))
        _ = screen.wait(20) { p.shown($0) && screen.quietFor > 1.5 }
        pty.write(Data("\u{1B}".utf8))
        let text = StatusDetector.stripANSI(screen.text).replacingOccurrences(of: "\r", with: "\n")
        return (p.parse(text), text)
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
