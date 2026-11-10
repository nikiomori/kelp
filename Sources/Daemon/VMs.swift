import Core
import CryptoKit
import Foundation
import os

/// Kelp's virtual machines (Core/VMs.swift): makes them, starts each one's `kelp-vm` and asks it how it is. Keeps nothing in
/// memory: a machine is its folder (a `creating` file while it's being made, `failed` after that went wrong). A machine's
/// own process outlives kelpd (started through `sh … &`, so it isn't kelpd's child): a restart or an upgrade here leaves
/// what runs inside alone.
struct VMService: Sendable {
    let root: URL
    /// kelp-vm, beside kelpd.
    let helper: String

    init(home: URL, helper: String) {
        root = home.appendingPathComponent("vms")
        self.helper = helper
    }

    func folder(_ name: String) -> URL { root.appendingPathComponent(name) }
    func file(_ name: String, _ file: String) -> URL { folder(name).appendingPathComponent(file) }
    var images: URL { root.appendingPathComponent(".images") }

    func machine(_ name: String) throws -> VMMachine {
        guard VMs.isName(name), let data = FileManager.default.contents(atPath: file(name, "machine.json").path) else {
            throw RPCError.invalidParams(
                "No machine called \(name). `kelp vm list` shows them; `kelp vm create \(name)` makes one.")
        }
        return try JSONDecoder().decode(VMMachine.self, from: data)
    }

    /// `sessions`: who works in each running one: what runs inside, read from inside (an SSH run each), and the session
    /// whose turn a macOS machine's screen is (an agent driving it runs nothing there).
    func list(sessions: Bool = false) -> [VMInfo] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }
        } catch { return [] }
        return names.sorted().compactMap { name in
            var entry: VMInfo
            let st = status(name)   // asked once per machine and poll: a busy kelp-vm takes up to 2 s to each
            do { entry = info(try machine(name), status: st) } catch { return nil }
            if sessions, entry.state == .running {
                let runs =
                    (entry.connections ?? 0) > 0 ? detail(name, status: st)?.runs.compactMap(\.session) ?? [] : []
                let screen = entry.machine.os == "macos" ? st?.screen.map { [$0] } ?? [] : []
                entry.sessions = Array(Set(runs + screen)).sorted()
            }
            return entry
        }
    }

    /// What runs in it, read over its own connection, which neither wakes it nor counts as use; nil unless it runs.
    func detail(_ name: String, status known: VMHelper.Reply?? = nil) -> VMDetail? {
        let st = known ?? status(name)
        // Android and iOS: none (no SSH inside them).
        let device = ["avd", "udid"].contains { FileManager.default.fileExists(atPath: file(name, $0).path) }
        guard st?.state == .running, !device else { return nil }
        let out: Subprocess.Output
        do {
            out = try Subprocess.run(
                [
                    "/usr/bin/ssh", "-F", file(name, "ssh_config").path, "-T", "-o", "BatchMode=yes", name + "-own",
                    "sh"
                ],
                cwd: "/", env: ProcessInfo.processInfo.environment, stdin: Data(VMs.detailScript.utf8), timeLimit: 10)
        } catch {
            Log.vm.info("reading \(name): \(error)")
            return nil
        }
        guard out.status == 0 else { return nil }
        var parsed = VMs.parseDetail(String(decoding: out.stdout, as: UTF8.self))
        parsed.guest?.screen = st?.screen   // whose turn the screen is: kelp-vm's to say now, not Kelp Guest's
        if let json = FileManager.default.contents(atPath: file(name, "shares.json").path) {
            do { parsed.folders = try JSONDecoder().decode([Int: String].self, from: json).values.sorted() } catch {
                Log.vm.error("\(name)'s shares: \(error)")
            }
        }
        return parsed
    }

    func info(_ machine: VMMachine, status known: VMHelper.Reply?? = nil) -> VMInfo {
        if let failed = failure(machine.name) { return VMInfo(machine: machine, state: .error, detail: failed) }
        if let at = making(machine.name) {
            var result = VMInfo(machine: machine, state: .creating, detail: at.detail)
            result.step = at.step
            result.progress = at.progress
            return result
        }
        var st = stat()
        let disk = stat(file(machine.name, "disk.img").path, &st) == 0 ? (Int(st.st_blocks) * 512) >> 20 : nil
        guard let reply = known ?? status(machine.name) else {
            let asleep = FileManager.default.fileExists(atPath: file(machine.name, "state.vzsave").path)
            var result = VMInfo(machine: machine, state: asleep ? .sleeping : .off, diskMiB: disk)
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

    func text(_ name: String, _ fileName: String) -> String? {
        FileManager.default.contents(atPath: file(name, fileName).path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Why it wasn't made: what failed, or that making it stopped midway (kelpd ended: its `creating` went stale).
    func failure(_ name: String) -> String? {
        if let failed = text(name, "failed") { return failed }
        guard text(name, "creating") != nil, making(name) == nil else { return nil }
        return String(localized: "Making it stopped midway (Kelp restarted). Delete it and make it again.")
    }

    /// What making it is at, unless that stopped (nothing updated it for 45 minutes, longer than a macOS first boot, its
    /// longest quiet step; a kelpd that started meanwhile goes on with it: `resumeMaking`).
    func making(_ name: String) -> VMMaking? {
        var st = stat()
        guard let data = FileManager.default.contents(atPath: file(name, "creating").path),
            stat(file(name, "creating").path, &st) == 0,
            Date().timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec) < 2700
        else { return nil }
        do { return try JSONDecoder().decode(VMMaking.self, from: data) } catch {   // a kelpd before 2026-11-06 wrote words
            return VMMaking(step: .starting, detail: String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: running

    func control(_ name: String, _ action: VMControl.Action) throws -> VMInfo {
        let machine = [.stop, .delete].contains(action) ? try self.machine(name) : try ready(name)
        switch action {
        case .delete:
            try discard(name, trash: true)
            var gone = VMInfo(machine: machine, state: .off)
            gone.detail = String(localized: "Deleted")
            return gone
        case .start:
            try wake(machine)
            try check(ask(name, .init(op: .start), wait: 620))
        case .show:
            guard machine.os != "linux" else {
                throw RPCError.invalidParams("\(name) has no screen: it's Linux. kelp vm run \(name) opens its shell.")
            }
            try wake(machine, show: true)   // begun with its window (Android's emulator starts headless otherwise)
            try check(ask(name, .init(op: .show), wait: VMControl.showWait))
        // Running by its lock, not by a status within 2 s, which a busy one may not give.
        case .sleep:
            if alive(name), try !asleep(ask(name, .init(op: .sleep), wait: 60)) {
                throw RPCError.invalidParams("\(name) is starting or being saved: put it to sleep in a moment.")
            }
        case .stop:
            if alive(name) {
                try check(ask(name, .init(op: .stop), wait: 60))
            } else {
                remove(file(name, "state.vzsave"))
            }
        }
        return info(machine)
    }

    /// The machine's ssh, with `cwd`'s project folder shared at its own path (the git repository's top, else `cwd`);
    /// no `cwd`: its home folder, nothing shared.
    func connect(_ name: String, cwd: String?) throws -> VMConnection {
        let machine = try ready(name)
        if machine.os == "ios" {   // simctl for its simulator, and its runner's port: booted first
            try wake(machine)
            let reply = try ask(name, .init(op: .start), wait: 620)
            try check(reply)
            guard let udid = reply.serial, let port = reply.port else {
                throw RPCError.internalError("\(name)'s simulator isn't up")
            }
            return VMConnection(ssh: ["/usr/bin/xcrun", "simctl"], prefix: "", device: udid, port: port)
        }
        if machine.os == "android" {   // adb to its emulator, booted or woken first
            try wake(machine)
            let reply = try ask(name, .init(op: .start), wait: 620)
            try check(reply)
            guard let adb = AndroidSDK.adb, let serial = reply.serial else {
                throw RPCError.internalError("\(name)'s emulator has no adb serial")
            }
            return VMConnection(ssh: [adb, "-s", serial], prefix: "")
        }
        let ssh = ["/usr/bin/ssh", "-F", file(name, "ssh_config").path, name]
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
        return VMConnection(ssh: ssh, prefix: VMs.prefix(slot: slot, folder: project, cwd: cwd, os: machine.os))
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
        let env = ProcessInfo.processInfo.environment
        do {
            let top = try Subprocess.run(
                ["/usr/bin/git", "-C", cwd, "rev-parse", "--show-toplevel"], cwd: "/", env: env, timeLimit: 10)
            if top.status == 0 { return String(decoding: top.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) }
        } catch { Log.vm.info("git for \(cwd): \(error)") }
        return cwd
    }

    /// Room made for `machine` (`admit`), then its kelp-vm started, one machine at a time (vms/.waking): two woken at
    /// once would both find room that's there for one, the other's kelp-vm not up yet to count.
    /// `show`: begun with its window, as `show` then asks.
    func wake(_ machine: VMMachine, show: Bool = false) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent(".waking").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw RPCError.internalError("Can't take the machines' wake lock: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        let up: Set<VMState> = [.running, .paused, .starting]
        // up already: nothing to make room for, nor to wait behind
        if let st = status(machine.name), up.contains(st.state) { return }
        // Waited for 90 s at most (one wake puts others to sleep, a minute each at worst), on this offload thread.
        let end = Date().addingTimeInterval(90)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < end else {
                throw RPCError.internalError("Another machine is still waking: try \(machine.name) again in a moment.")
            }
            usleep(100_000)
        }
        try admit(machine)
        try startHelper(machine)
        // Starting before the lock is let go (answered at once, `begin`): the next wake counts it, as it's `.starting` now.
        do { try check(ask(machine.name, .begin(show: show), wait: 10)) } catch {
            Log.vm.error("\(machine.name) didn't begin starting: \(error)")
        }
    }

    /// Room in the memory budget (a quarter of the Mac's) for `machine` to wake: idle machines are put to sleep for it,
    /// else no. One alone wakes at any size it may have (up to half the Mac's): the budget is for them together.
    func admit(_ machine: VMMachine) throws {
        let up: Set<VMState> = [.running, .paused, .starting]
        if let me = status(machine.name), up.contains(me.state) { return }
        let budget = Int(ProcessInfo.processInfo.physicalMemory >> 20) / 4
        var awake = list().filter { $0.machine.name != machine.name && up.contains($0.state) }
        // By the size each is given, not what it holds now (`memoryMiB`, its footprint): a guest just booted grows to it.
        func used() -> Int { awake.reduce(machine.memoryMiB) { $0 + $1.machine.memoryMiB } }
        let idle = awake.filter { $0.connections == 0 }.sorted { $0.machine.memoryMiB > $1.machine.memoryMiB }
        for other in idle where used() > budget {
            // Freed only once it says it's asleep: one still starting, a failed save or an Intel Mac keeps its memory, and
            // so does one in use since it was listed (`sleepIfIdle`: the machine itself refuses).
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
        // not "it answered": a busy one may not within 2 s, and a second would only end
        if alive(machine.name) { return }
        let log = file(machine.name, "helper.log").path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw RPCError.internalError("This build of Kelp has no kelp-vm beside kelpd (\(helper)).")
        }
        let line =
            "\(IDE.shellWord(helper)) \(IDE.shellWord(folder(machine.name).path)) >> \(IDE.shellWord(log))"
            + " 2>&1 < /dev/null &"
        _ = try Subprocess.run(
            ["/bin/sh", "-c", line], cwd: "/", env: ProcessInfo.processInfo.environment, timeLimit: 10)
        for _ in 0..<50 {
            if status(machine.name) != nil { return }
            usleep(100_000)
        }
        let tail = text(machine.name, "helper.log")?.split(separator: "\n").suffix(3).joined(separator: "\n") ?? ""
        try check(
            VMHelper.Reply(state: .error, connections: 0, error: "\(machine.name)'s kelp-vm didn't start: \(tail)"))
    }

    /// How it is, from its kelp-vm; nil when that isn't running.
    func status(_ name: String) -> VMHelper.Reply? {
        do { return try ask(name, .init(op: .status), wait: 2) } catch { return nil }
    }

    /// One request to the machine's kelp-vm; `wait` seconds for its answer.
    func ask(_ name: String, _ request: VMHelper.Request, wait: TimeInterval) throws -> VMHelper.Reply {
        // One that just took its lock may not listen yet: tried again for a second while it holds it.
        var fd: Int32 = -1
        for tries in 0... {
            do {
                fd = try Unix.connect(file(name, "ctl.sock").path)
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

    /// Its kelp-vm gone, the machine off at once: before its folder is (deleted, or made again).
    func quit(_ name: String) {
        guard alive(name) else { return }
        do { _ = try ask(name, .init(op: .quit), wait: 10) } catch { Log.vm.info("\(name) quit: \(error)") }   // it hangs up as it goes
        for _ in 0..<100 where alive(name) { usleep(100_000) }
    }

    /// The machine gone: its kelp-vm, an iOS one's simulator (it lives in Xcode's device set), its folder, its password.
    /// Limit: an emulator or runner left by a kelp-vm that was killed (SIGKILL: no leave) is ended by that machine's next
    /// start (`Lifecycle.endLeftover`, from the pid noted in its folder), not here: deleted first, it runs on until it's
    /// quit by hand.
    /// `trash`: a machine the user deletes goes to the Trash (its disk is their work); a failed try's remains don't.
    func discard(_ name: String, trash: Bool = false) throws {
        quit(name)
        guard !alive(name) else {
            throw RPCError.internalError("\(name) didn't stop: try again in a moment, or restart the Mac.")
        }
        if let udid = text(name, "udid") {
            do {
                try run(["/usr/bin/xcrun", "simctl", "delete", udid.trimmingCharacters(in: .whitespacesAndNewlines)])
            } catch { Log.vm.error("deleting \(name)'s simulator: \(error)") }
        }
        if trash { try Trash.move(folder(name)) } else { try FileManager.default.removeItem(at: folder(name)) }
        Keychain.delete("vm." + name)
    }

    /// Whether the machine's kelp-vm runs: it holds `kelp-vm.lock` while it does. Not "it answered", which a busy one
    /// (its control socket is served on its main queue) may not do within a status's 2 s.
    func alive(_ name: String) -> Bool {
        let fd = open(file(name, "kelp-vm.lock").path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // Shared: two of kelpd's looks at once (a poll, a delete) don't take each other for a kelp-vm, which holds it whole.
        return flock(fd, LOCK_SH | LOCK_NB) != 0
    }

    /// A sleep's answer: an error thrown, else whether it's down now (`sleep` leaves one that's starting as it is).
    func asleep(_ reply: VMHelper.Reply) throws -> Bool {
        try check(reply)
        return ![.running, .paused, .starting].contains(reply.state)
    }

    func check(_ reply: VMHelper.Reply) throws {
        guard let message = reply.error else { return }
        guard message.contains("entitlement") else { throw RPCError.internalError(message) }
        // A debug build: `swift build` links kelp-vm anew, without the entitlement scripts/bundle.sh signs it with.
        throw RPCError.internalError(
            "kelp-vm isn't signed for virtualization: "
                + "codesign --force --sign - --entitlements Resources/KelpVM.entitlements \(helper)")
    }

    func remove(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        Log.vm.attempt("removing \(url.path)") { try FileManager.default.removeItem(at: url) }
    }
}
