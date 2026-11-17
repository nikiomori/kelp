import Core
import Foundation
import GitKit
import os

/// Kelp's virtual machines (Core/VM/VMs.swift). This service makes them, starts each machine's `kelp-vm` and asks it
/// how the machine is. It keeps nothing in memory, because a machine is its folder (with a `creating` file while it is
/// being made, and `failed` after that went wrong). A machine's own process outlives kelpd, because it is started
/// through `sh … &` and so isn't kelpd's child. So restarting or upgrading kelpd leaves what runs inside the machine
/// alone.
struct VMService: Sendable {
    let root: URL
    /// The path of kelp-vm, which sits beside kelpd.
    let helper: String

    init(home: URL, helper: String) {
        root = home.appendingPathComponent("vms")
        self.helper = helper
    }

    func folder(_ name: String) -> VMFolder { VMFolder(root.appendingPathComponent(name)) }
    var images: URL { root.appendingPathComponent(".images") }

    func machine(_ name: String) throws -> VMMachine {
        guard VMs.isName(name), let data = FileManager.default.contents(atPath: folder(name).machine.path) else {
            throw RPCError.invalidParams(
                "No machine called \(name). `kelp vm list` shows them; `kelp vm create \(name)` makes one.")
        }
        return try JSONDecoder().decode(VMMachine.self, from: data)
    }

    /// Lists the machines. With `sessions`, each running machine also lists the sessions working in it. Those are the
    /// sessions of what runs inside, read from inside (one SSH run per machine), and the session whose turn it is on a
    /// macOS machine's screen, because an agent driving the screen runs nothing inside.
    func list(sessions: Bool = false) -> [VMInfo] {
        let names = FileManager.default.names(in: root.path).filter { !$0.hasPrefix(".") }
        return names.sorted().compactMap { name in
            var entry: VMInfo
            let st = status(name)   // asked once per machine per poll, as a busy kelp-vm takes up to 2 s each time
            do { entry = info(try machine(name), status: st) } catch { return nil }
            if sessions, entry.state == .running {
                let runs =
                    (entry.connections ?? 0) > 0 ? detail(name, status: st)?.runs.compactMap(\.session) ?? [] : []
                let screen = entry.machine.kind == .macos ? st?.screen.map { [$0] } ?? [] : []
                entry.sessions = Array(Set(runs + screen)).sorted()
            }
            return entry
        }
    }

    /// Returns what runs in the machine, read over the machine's own connection, which neither wakes it nor counts as
    /// use. Returns nil unless the machine runs.
    func detail(_ name: String, status known: VMHelper.Reply?? = nil) -> VMDetail? {
        let st = known ?? status(name)
        // Android and iOS machines have no detail, because there is no SSH inside them.
        let device = [folder(name).avd, folder(name).udid].contains { FileManager.default.fileExists(atPath: $0.path) }
        guard st?.state == .running, !device else { return nil }
        let out: Subprocess.Output
        do {
            out = try Subprocess.run(
                [
                    "/usr/bin/ssh", "-F", folder(name).sshConfig.path, "-T", "-o", "BatchMode=yes", name + "-own",
                    "sh"
                ],
                cwd: "/", env: ProcessInfo.processInfo.environment, stdin: Data(VMs.detailScript.utf8), timeLimit: 10)
        } catch {
            Log.vm.info("reading \(name): \(error)")
            return nil
        }
        guard out.status == 0 else { return nil }
        var parsed = VMs.parseDetail(String(decoding: out.stdout, as: UTF8.self))
        parsed.guest?.screen = st?.screen   // kelp-vm, not Kelp Guest, now says whose turn the screen is
        if let json = FileManager.default.contents(atPath: folder(name).shares.path) {
            do { parsed.folders = try JSONDecoder().decode([Int: String].self, from: json).values.sorted() } catch {
                Log.vm.error("\(name)'s shares: \(error)")
            }
        }
        return parsed
    }

    func info(_ machine: VMMachine, status known: VMHelper.Reply?? = nil) -> VMInfo {
        var result = describe(machine, status: known)
        let log = folder(machine.name).log.path
        result.log = FileManager.default.fileExists(atPath: log) ? log : nil
        return result
    }

    private func describe(_ machine: VMMachine, status known: VMHelper.Reply??) -> VMInfo {
        if let failed = failure(machine.name) {
            var result = VMInfo(machine: machine, state: .error, detail: failed)
            result.notMade = true
            return result
        }
        if let at = making(machine.name) {
            var result = VMInfo(machine: machine, state: .creating, detail: at.detail)
            result.step = at.step
            result.progress = at.progress
            return result
        }
        var st = stat()
        let disk = stat(folder(machine.name).disk.path, &st) == 0 ? (Int(st.st_blocks) * 512) >> 20 : nil
        guard let reply = known ?? status(machine.name) else {
            var result = VMInfo(machine: machine, state: folder(machine.name).restingState(machine), diskMiB: disk)
            result.files = filesFolder(machine)
            return result
        }
        var result = VMInfo(
            machine: machine, state: reply.state, detail: reply.error, connections: reply.connections,
            memoryMiB: reply.memoryMiB,
            diskMiB: disk)
        result.files = filesFolder(machine)
        result.cpu = reply.cpu
        return result
    }

    func text(_ file: URL) -> String? {
        FileManager.default.contents(atPath: file.path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Returns why the machine wasn't made: what failed, or that making it stopped midway because kelpd ended and the
    /// `creating` file went stale.
    func failure(_ name: String) -> String? {
        if let failed = text(folder(name).failed) { return failed }
        guard text(folder(name).creating) != nil, making(name) == nil else { return nil }
        return String(localized: "Making it stopped midway (Kelp restarted). Delete it and make it again.")
    }

    /// Returns how far making the machine got, unless making stopped. It counts as stopped when nothing updated it for
    /// 45 minutes, which is longer than a macOS first boot, the longest quiet step. A kelpd that started meanwhile goes
    /// on with the making (`resumeMaking`).
    func making(_ name: String) -> VMMaking? {
        var st = stat()
        guard let data = FileManager.default.contents(atPath: folder(name).creating.path),
            stat(folder(name).creating.path, &st) == 0,
            Date().timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec) < 2700
        else { return nil }
        // A kelpd from before 2026-11-06 wrote plain words here, not JSON.
        do { return try JSONDecoder().decode(VMMaking.self, from: data) } catch {
            return VMMaking(step: .starting, detail: String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: running

    func control(_ name: String, _ action: VMControl.Action) throws -> VMInfo {
        let machine = [.stop, .delete].contains(action) ? try self.machine(name) : try ready(name)
        switch action {
        case .delete:
            // A machine deleted while it's being made first has what makes it ended (its download stops at its next
            // step). Only a made machine's disk is the user's work, so only that goes to the Trash.
            let made = making(name) == nil && failure(name) == nil
            if !made { endLeftovers(name) }
            try discard(name, trash: made)
            var gone = VMInfo(machine: machine, state: .off)
            gone.detail = String(localized: "Deleted")
            return gone
        case .start:
            try wake(machine)
            try check(ask(name, .init(op: .start), wait: 620))
        case .show:
            guard machine.kind.hasScreen else {
                throw RPCError.invalidParams("\(name) has no screen: it's Linux. kelp vm run \(name) opens its shell.")
            }
            try wake(machine, show: true)   // begun with its window, since Android's emulator starts headless otherwise
            try check(ask(name, .init(op: .show), wait: VMControl.showWait))
        // Whether kelp-vm runs is told by its lock, not by a status within 2 s, which a busy kelp-vm may not give.
        case .sleep:
            if alive(name), try !asleep(ask(name, .init(op: .sleep), wait: 60)) {
                throw RPCError.invalidParams("\(name) is starting or being saved: put it to sleep in a moment.")
            }
        case .stop:
            if alive(name) {
                try check(ask(name, .init(op: .stop), wait: 60))
            } else {
                endChildren(name)   // what a killed kelp-vm left runs on and holds memory
                if let kept = folder(name).sleepState(machine) { remove(kept) }   // and an Android snapshot
            }
        }
        return info(machine)
    }

    /// Returns how to reach the machine: ssh, with the project folder of `cwd` shared at its own path (the git
    /// repository's top, else `cwd`). With no `cwd`, commands run in the machine's home folder and nothing is shared.
    /// An iOS machine is reached through simctl and an Android machine through adb.
    func connect(_ name: String, cwd: String?) throws -> VMConnection {
        let machine = try ready(name)
        if machine.kind == .ios {   // simctl for its simulator and the runner's port, booted first
            try wake(machine)
            let reply = try ask(name, .init(op: .start), wait: 620)
            try check(reply)
            guard let udid = reply.serial, let port = reply.port else {
                throw RPCError.internalError("\(name)'s simulator isn't up")
            }
            return VMConnection(ssh: ["/usr/bin/xcrun", "simctl"], prefix: "", device: udid, port: port)
        }
        if machine.kind == .android {   // adb to its emulator, booted or woken first
            try wake(machine)
            let reply = try ask(name, .init(op: .start), wait: 620)
            try check(reply)
            guard let adb = AndroidSDK.adb, let serial = reply.serial else {
                throw RPCError.internalError("\(name)'s emulator has no adb serial")
            }
            return VMConnection(ssh: [adb, "-s", serial], prefix: "")
        }
        let ssh = ["/usr/bin/ssh", "-F", folder(name).sshConfig.path, name]
        guard let cwd else {
            try wake(machine)
            return VMConnection(ssh: ssh, prefix: "cd || exit 1; ")
        }
        let project = projectFolder(cwd)
        guard VMs.mayShare(project) else {
            throw RPCError.invalidParams(
                "\(project) can't be shared with a machine: only folders inside your home folder "
                    + "(not it, ~/.ssh or ~/Library). Pass --cwd <project folder>.")
        }
        try wake(machine)
        let shared = try ask(name, .init(op: .share, path: project), wait: 5)
        try check(shared)
        guard let slot = shared.slot else { throw RPCError.internalError("\(name) didn't share \(project)") }
        return VMConnection(ssh: ssh, prefix: VMs.prefix(slot: slot, folder: project, cwd: cwd, os: machine.kind))
    }

    func ready(_ name: String) throws -> VMMachine {
        let machine = try self.machine(name)
        if let failed = failure(name) { throw RPCError.invalidParams("\(name) wasn't made: \(failed)") }
        if making(name) != nil {
            throw RPCError.invalidParams("\(name) is still being made: `kelp vm list` shows how far.")
        }
        return machine
    }

    private func projectFolder(_ cwd: String) -> String {
        do { return try Git.root(of: cwd, remotes: .none) } catch {
            Log.vm.info("git for \(cwd): \(error)")
            return cwd
        }
    }

    /// Makes room for `machine` (`admit`), then starts its kelp-vm, one machine at a time (vms/.waking). Two machines
    /// woken at once would both find room that's there for one, because the other's kelp-vm isn't up yet to be
    /// counted. With `show`, the machine begins with its window, as `show` then asks.
    func wake(_ machine: VMMachine, show: Bool = false) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent(".waking").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw RPCError.internalError("Can't take the machines' wake lock: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        // A machine that is up already has nothing to make room for or wait behind.
        if status(machine.name)?.state.isUp == true { return }
        // The lock is waited for 90 s at most, on this offload thread, because one wake puts others to sleep, a
        // minute each at worst.
        let end = Date().addingTimeInterval(90)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < end else {
                throw RPCError.internalError("Another machine is still waking: try \(machine.name) again in a moment.")
            }
            usleep(100_000)
        }
        try admit(machine)
        try startHelper(machine)
        // The machine begins starting before the lock is let go (`begin` is answered at once). So the next wake
        // counts it, as it's `.starting` now.
        do { try check(ask(machine.name, .begin(show: show), wait: 10)) } catch {
            Log.vm.error("\(machine.name) didn't begin starting: \(error)")
        }
    }

    /// Makes room in the memory budget (a quarter of the Mac's memory) for `machine` to wake. Idle machines are put to
    /// sleep for it, or the answer is no. A machine running alone wakes at any size it may have (up to half the Mac's
    /// memory), since the budget is for all of them together.
    func admit(_ machine: VMMachine) throws {
        if status(machine.name)?.state.isUp == true { return }
        let budget = Int(ProcessInfo.processInfo.physicalMemory >> 20) / 4
        var awake = list().filter { $0.machine.name != machine.name && $0.state.isUp }
        // This counts the size each machine is given, not what it holds now (`memoryMiB`, its footprint), because a
        // guest that just booted grows to its size.
        func used() -> Int { awake.reduce(machine.memoryMiB) { $0 + $1.machine.memoryMiB } }
        let idle = awake.filter { $0.connections == 0 }.sorted { $0.machine.memoryMiB > $1.machine.memoryMiB }
        for other in idle where used() > budget {
            // A machine's memory counts as freed only once it says it's asleep. One still starting, one whose save
            // failed, or one on an Intel Mac keeps its memory. So does one in use since it was listed, because the
            // machine itself refuses `sleepIfIdle`.
            do { guard try asleep(ask(other.machine.name, .sleepIfIdle, wait: 60)) else { continue } } catch {
                Log.vm.info("\(other.machine.name) wasn't put to sleep for \(machine.name): \(error)")
                continue
            }
            awake.removeAll { $0.machine.name == other.machine.name }
        }
        guard awake.isEmpty || used() <= budget else {
            let busy = awake.map { $0.machine.name }.joined(separator: ", ")
            throw RPCError.invalidParams(
                "Not enough of the machines' memory budget (\(budget >> 10) GB) to wake \(machine.name): "
                    + "\(busy) are in use. Put one to sleep: kelp vm sleep <name>.")
        }
    }

    /// Starts the machine's `kelp-vm` unless it runs.
    func startHelper(_ machine: VMMachine) throws {
        // Running is told by the lock, not by an answer, because a busy kelp-vm may not answer within 2 s, and a
        // second kelp-vm would only end.
        if alive(machine.name) { return }
        let log = folder(machine.name).log.path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw RPCError.internalError("This build of Kelp has no kelp-vm beside kelpd (\(helper)).")
        }
        let line =
            "\(ShellQuote.word(helper)) \(ShellQuote.word(folder(machine.name).path)) >> \(ShellQuote.word(log))"
            + " 2>&1 < /dev/null &"
        _ = try Subprocess.run(
            ["/bin/sh", "-c", line], cwd: "/", env: ProcessInfo.processInfo.environment, timeLimit: 10)
        for _ in 0..<50 {
            if status(machine.name) != nil { return }
            usleep(100_000)
        }
        let tail = text(folder(machine.name).log)?.split(separator: "\n").suffix(3).joined(separator: "\n") ?? ""
        try check(
            VMHelper.Reply(state: .error, connections: 0, error: "\(machine.name)'s kelp-vm didn't start: \(tail)"))
    }

    /// Returns the machine's status from its kelp-vm, or nil when kelp-vm isn't running.
    func status(_ name: String) -> VMHelper.Reply? {
        do { return try ask(name, .init(op: .status), wait: 2) } catch { return nil }
    }

    /// Sends one request to the machine's kelp-vm and waits `wait` seconds for its answer.
    func ask(_ name: String, _ request: VMHelper.Request, wait: TimeInterval) throws -> VMHelper.Reply {
        // A kelp-vm that just took its lock may not listen yet, so connecting is tried again for a second while it
        // holds the lock.
        var fd: Int32 = -1
        for tries in 0... {
            do {
                fd = try Unix.connect(folder(name).control.path)
                break
            } catch {
                guard tries < 10, alive(name) else { throw error }
                usleep(100_000)
            }
        }
        defer { close(fd) }
        guard Unix.writeAll(fd, try Wire.line(request)) else {
            throw RPCError.internalError("\(name)'s kelp-vm hung up")
        }
        var line = Data(), byte: UInt8 = 0
        let end = Date().addingTimeInterval(wait)
        while true {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(0, end.timeIntervalSinceNow) * 1000)
            guard left > 0, poll(&pollFD, 1, left) > 0, read(fd, &byte, 1) == 1 else {
                throw RPCError.internalError("\(name) didn't answer in \(Int(wait)) s")
            }
            if byte == 0x0A { break }
            line.append(byte)
        }
        return try JSONDecoder().decode(VMHelper.Reply.self, from: line)
    }

    /// Quits the machine's kelp-vm, which turns the machine off at once, before the machine's folder goes (deleted, or
    /// made again). A kelp-vm still there after `patience` (stuck in Virtualization) is killed by the pid it noted as
    /// it took its lock.
    func quit(_ name: String, patience: TimeInterval = 10) {
        guard alive(name) else { return }
        // kelp-vm may hang up as it quits, which is only logged.
        do { _ = try ask(name, .init(op: .quit), wait: patience) } catch { Log.vm.info("\(name) quit: \(error)") }
        let end = Date().addingTimeInterval(patience)
        while alive(name), Date() < end { usleep(100_000) }
        guard alive(name), let pid = folder(name).endChild(VMFolder.helperNote) else { return }
        Log.vm.error("\(name)'s kelp-vm \(pid) didn't quit: killed")
        for _ in 0..<20 where alive(name) { usleep(100_000) }   // the lock goes when the process does
    }

    /// Removes the machine: its kelp-vm, what a killed kelp-vm left (an emulator, a runner), an iOS machine's simulator
    /// (which lives in Xcode's device set), its folder and its password. With `trash`, a machine the user deletes goes
    /// to the Trash, because its disk is their work. What a failed try left doesn't.
    func discard(_ name: String, trash: Bool = false) throws {
        quit(name)
        guard !alive(name) else {
            throw RPCError.internalError("\(name) didn't stop: try again in a moment, or restart the Mac.")
        }
        endChildren(name)
        deleteSimulator(name)
        if trash { try Trash.move(folder(name).url) } else { try FileManager.default.removeItem(at: folder(name).url) }
        Keychain.delete("vm." + name)
    }

    /// Deletes an iOS machine's simulator. Other machines have none.
    func deleteSimulator(_ name: String) {
        guard let udid = text(folder(name).udid) else { return }
        do {
            try run(["/usr/bin/xcrun", "simctl", "delete", udid.trimmingCharacters(in: .whitespacesAndNewlines)])
        } catch { Log.vm.error("deleting \(name)'s simulator: \(error)") }
    }

    /// Returns whether the machine's kelp-vm runs, which it does while it holds `kelp-vm.lock`. It doesn't wait for an
    /// answer, because a busy kelp-vm (its control socket is served on its main queue) may not answer within a
    /// status's 2 s.
    func alive(_ name: String) -> Bool {
        let fd = open(folder(name).lock.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // The check takes a shared lock, so two of kelpd's checks at once (a poll, a delete) don't take each other for
        // a kelp-vm, which holds the lock exclusively.
        return flock(fd, LOCK_SH | LOCK_NB) != 0
    }

    /// Reads a sleep's answer: it throws the error, or returns whether the machine is down now (`sleep` leaves a
    /// machine that is starting as it is).
    func asleep(_ reply: VMHelper.Reply) throws -> Bool {
        try check(reply)
        return !reply.state.isUp
    }

    func check(_ reply: VMHelper.Reply) throws {
        guard let message = reply.error else { return }
        guard message.contains("entitlement") else { throw RPCError.internalError(message) }
        // This happens in a debug build, because `swift build` links kelp-vm anew, without the entitlement that
        // scripts/bundle.sh signs it with.
        throw RPCError.internalError(
            "kelp-vm isn't signed for virtualization: "
                + "codesign --force --sign - --entitlements Resources/KelpVM.entitlements \(helper)")
    }

    func remove(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        Log.vm.attempt("removing \(url.path)") { try FileManager.default.removeItem(at: url) }
    }
}
