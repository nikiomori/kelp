import Core
import Foundation

/// What runs under each session's PTY, read when asked (nothing samples in the background): the dev servers a
/// workspace started (ports, from the kernel) and what each session costs (CPU, memory, with ps). For a remote project,
/// its ports forwarded to this Mac, and the host's own load (`host.stats`).
final class SessionProcesses: Sendable {
    typealias Port = PortsList.Port
    typealias Usage = SessionUsage.Usage
    let live: SessionTable, store: Store, remotes: Remotes
    let forwards: Forwards
    /// Remote hosts whose last connection failed, and ssh's reason (`host.stats`).
    let hostErrors = HostErrors(initialState: [:])

    init(live: SessionTable, store: Store, remotes: Remotes) {
        self.live = live
        self.store = store
        self.remotes = remotes
        forwards = Forwards(store: store)
    }

    /// Every process under a live session's PTY, by pid → session id; `only` limits it to one workspace.
    private func owners(worktree only: String? = nil) -> [Int32: String] {
        var owner: [Int32: String] = [:]
        for ls in live.all where only == nil || ls.snapshot.worktreeId == only {
            for pid in ls.pty.tree() { owner[pid] = ls.snapshot.id }
        }
        return owner
    }

    private func sessionProcesses() -> (owner: [Int32: String], rows: [Int32: (cpu: Double, rss: Int)]) {
        let owner = owners()
        var rows: [Int32: (cpu: Double, rss: Int)] = [:]
        guard !owner.isEmpty else { return ([:], [:]) }
        let ps = Subprocess.printed(["/bin/ps", "-axo", "pid=,pcpu=,rss="], path: "/bin:/usr/bin", timeout: 3) ?? ""
        for line in ps.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 3, let pid = Int32(fields[0]) else { continue }
            rows[pid] = (Double(fields[1]) ?? 0, (Int(fields[2]) ?? 0) * 1024)
        }
        return (owner, rows)
    }

    /// Read every 3 s while the window shows, so from the kernel: lsof and ps cost 2 % of a core for as long as Kelp is open.
    func ports(worktree wid: String) -> [Port] {
        if let (worktree, remote) = remote(wid) {
            return forwards.ports(
                worktree, remote, sessions: live.all.filter { $0.snapshot.worktreeId == wid }.map(\.snapshot.id))
        }
        var out: [Int: Port] = [:]
        for (pid, session) in owners(worktree: wid).sorted(by: { $0.key < $1.key }) {
            for port in Self.listening(pid) where out[port] == nil {
                out[port] = Port(port: port, pid: pid, command: Self.name(of: pid), session: session)
            }
        }
        return out.values.sorted { $0.port < $1.port }
    }

    /// The workspace when it's a remote project's.
    func remote(_ wid: String) -> (Worktree, RemoteHost)? {
        guard let worktree = Log.store.attempt("reading a workspace", { try store.worktree(wid) }).flatMap({ $0 }),
            let remote = remotes.of(worktree.path)
        else { return nil }
        return (worktree, remote)
    }

    /// The TCP ports a process listens on. Nothing for one that's gone.
    static func listening(_ pid: Int32) -> [Int] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0), stride = MemoryLayout<proc_fdinfo>.stride
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let got = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)) / stride
        return fds.prefix(max(0, got)).compactMap { fd in
            guard fd.proc_fdtype == PROX_FDTYPE_SOCKET else { return nil }
            var info = socket_fdinfo()
            guard
                proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
                    > 0,
                info.psi.soi_kind == SOCKINFO_TCP, info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else { return nil }
            return Int(UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport).bigEndian)
        }
    }

    private static func name(of pid: Int32) -> String {
        var name = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &name, UInt32(name.count)) > 0 ? String(cBuffer: name) : ""
    }

    /// CPU (ps's %, summed over the session's processes; 100 = one core) and resident memory per live session.
    func usage() -> [Usage] {
        let (owner, rows) = sessionProcesses()
        var by: [String: Usage] = [:]
        for (pid, sid) in owner {
            guard let row = rows[pid] else { continue }
            var total = by[sid] ?? Usage(session: sid, cpu: 0, memory: 0, processes: 0)
            total.cpu += row.cpu
            total.memory += row.rss
            total.processes += 1
            by[sid] = total
        }
        return by.values.filter { $0.memory > 0 }.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }   // 0: already gone
    }
}

extension Subprocess {
    /// What a short command prints (stdout, then stderr), or nil if it fails or takes longer than `timeout`.
    static func printed(_ argv: [String], path: String, timeout: Double) -> String? {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["NO_COLOR"] = "1"
        guard let result = try? Subprocess.run(argv, cwd: NSHomeDirectory(), env: env, timeLimit: timeout),
            result.status == 0, !result.timedOut, !result.truncated
        else { return nil }
        return String(decoding: result.stdout + result.stderr, as: UTF8.self)
    }
}
