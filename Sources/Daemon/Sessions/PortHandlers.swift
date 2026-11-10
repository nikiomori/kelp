import Core
import Foundation

// ports.* and session.usage: what the sessions' processes listen on and use, stopping one, forwarding a host's port.

extension PortsList: Handled {
    func handle(_ processes: SessionProcesses) throws -> [Port] { processes.ports(worktree: worktreeId) }
}
extension SessionUsage: Handled {
    func handle(_ processes: SessionProcesses) throws -> [Usage] { processes.usage() }
}

extension PortsStop: Handled {
    var inWorkspace: String? { worktreeId }   // said, not left to the walk: it stops a process, and an id of no workspace finds none
    func handle(_ processes: SessionProcesses) throws -> Done {
        let pid = Int32(clamping: pid ?? 0)
        guard pid > 0, processes.ports(worktree: worktreeId).contains(where: { $0.pid == pid }) else {
            throw RPCError.invalidParams("That process isn't running in this workspace.")
        }
        if let (_, remote) = processes.remote(worktreeId) {
            try Subprocess.output([remote.ssh] + remote.sshArgs(tty: false) + ["kill \(pid)"], cwd: NSHomeDirectory())
        } else {
            kill(pid, SIGTERM)
        }
        return Done()
    }
}

extension PortsForward: Handled {
    func handle(_ processes: SessionProcesses) throws -> Forwarded {
        guard let (worktree, remote) = processes.remote(worktreeId) else {
            throw RPCError.invalidParams("Only a remote project's ports are forwarded.")
        }
        let forwards = processes.forwards
        let goal = try target.map(Forwards.target) ?? port.map { forwards.target(port: $0, in: worktree.id) }
        guard let goal else { throw RPCError.invalidParams("missing port") }
        return Forwarded(port: try forwards.forward(goal, in: worktree.id, remote, manual: target != nil))
    }
}

extension PortsUnforward: Handled {
    func handle(_ processes: SessionProcesses) throws -> Done {
        if let (worktree, remote) = processes.remote(worktreeId) {
            processes.forwards.drop(port: port, in: worktree.id, remote)
        }
        return Done()
    }
}

extension Methods {
    static let portMethods: [any Answered.Type] = [
        PortsList.self, SessionUsage.self, PortsStop.self, PortsForward.self, PortsUnforward.self
    ]
}
