import Foundation
import Core

/// What runs under each session's PTY, read when asked (nothing samples in the background): the dev servers a
/// workspace started (ports, from the kernel) and what each session costs (CPU, memory, with ps).
extension Sessions {
    typealias Port = PortsList.Port
    typealias Usage = SessionUsage.Usage

    /// Every process under a live session's PTY, by pid → session id; `only` limits it to one workspace.
    private func owners(worktree only: String? = nil) -> [Int32: String] {
        var owner: [Int32: String] = [:]
        for ls in live.all where only == nil || ls.snapshot.worktreeId == only { for p in ls.pty.tree() { owner[p] = ls.snapshot.id } }
        return owner
    }

    private func sessionProcesses() -> (owner: [Int32: String], rows: [Int32: (cpu: Double, rss: Int)]) {
        let owner = owners()
        var rows: [Int32: (cpu: Double, rss: Int)] = [:]
        guard !owner.isEmpty else { return ([:], [:]) }
        for line in (Self.run(["/bin/ps", "-axo", "pid=,pcpu=,rss="], path: "/bin:/usr/bin", timeout: 3) ?? "").split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ")
            guard f.count == 3, let pid = Int32(f[0]) else { continue }
            rows[pid] = (Double(f[1]) ?? 0, (Int(f[2]) ?? 0) * 1024)
        }
        return (owner, rows)
    }

    /// Read every 3 s while the window shows, so from the kernel: lsof and ps cost 2 % of a core for as long as Kelp is open.
    func ports(worktree wid: String) -> [Port] {
        if let (w, remote) = remote(wid) {
            return forwards.ports(w, remote, sessions: live.all.filter { $0.snapshot.worktreeId == wid }.map(\.snapshot.id))
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
        guard let w = Log.store.attempt("reading a workspace", { try store.worktree(wid) }).flatMap({ $0 }), let r = remotes.of(w.path) else { return nil }
        return (w, r)
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
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
                  info.psi.soi_kind == SOCKINFO_TCP, info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { return nil }
            return Int(UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport).bigEndian)
        }
    }

    private static func name(of pid: Int32) -> String {
        var name = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &name, UInt32(name.count)) > 0 ? String(cString: name) : ""
    }

    /// CPU (ps's %, summed over the session's processes; 100 = one core) and resident memory per live session.
    func usage() -> [Usage] {
        let (owner, rows) = sessionProcesses()
        var by: [String: Usage] = [:]
        for (pid, sid) in owner {
            guard let r = rows[pid] else { continue }
            var u = by[sid] ?? Usage(session: sid, cpu: 0, memory: 0, processes: 0)
            u.cpu += r.cpu
            u.memory += r.rss
            u.processes += 1
            by[sid] = u
        }
        return by.values.filter { $0.memory > 0 }.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }   // 0: already gone
    }
}
