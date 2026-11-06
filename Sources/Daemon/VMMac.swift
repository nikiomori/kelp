import Foundation
import os
import Core

/// Making a macOS machine (`VMService.create` with the macos image).
extension VMService {
    /// Apple's latest macOS for this Mac, downloaded (and dropped once installed: it's 20 GB and more), installed, and set up
    /// by itself on its first boot: an account with a random password (in the Keychain, "vm.<name>"), signed in, Remote
    /// Login on. Then, over SSH with that password once: Kelp's key, sudo without a password, and a screen that never sleeps.
    /// `given`: the user's own restore image, installed as it is and left where it is.
    func makeMac(_ m: VMMachine, ipsw given: URL? = nil) async {
        await making(m) {
            var ipsw = given ?? images, version = given?.deletingPathExtension().lastPathComponent ?? ""
            if given == nil {
                step(m, .asking)
                let latest = try await blocking { try run([helper, "--latest"], limit: 120) }
                struct Latest: Decodable { var url: String, build: String, version: String }
                let l = try JSONDecoder().decode(Latest.self, from: Data(latest.utf8))
                try Paths.ensure(images)
                ipsw = images.appendingPathComponent("macos-\(l.build).ipsw")
                version = "macOS \(l.version)"
                if !FileManager.default.fileExists(atPath: ipsw.path) {
                    let title = version
                    try await download(l.url, to: ipsw) { step(m, .downloading, title, progress: $0) }
                }
            }
            try await blocking { try makeMacFolder(m) }
            step(m, .installing, version)
            let image = ipsw
            try await blocking { _ = try run([helper, "--install", folder(m.name).path, image.path], limit: 3600) }
            if given == nil { remove(ipsw) }   // ours, and over 20 GB: the user's own stays
            step(m, .firstBoot)
            try await blocking { try startHelper(m); try check(ask(m.name, .init(op: .start), wait: 1800)) }
            step(m, .lettingIn)
            try await blocking { try letKelpIn(m); try installGuest(m) }
        }
    }

    /// A macOS machine's screen, read or driven from the Mac's side by its kelp-vm (`VMScreen`), waking it first.
    func screen(_ name: String, _ args: [String], session: String?) throws {
        let m = try ready(name)
        guard m.os == "macos" else { throw RPCError.invalidParams("\(name) isn't a macOS machine: its screen goes through adb or the simulator.") }
        try admit(m)
        try startHelper(m)
        try check(ask(name, .init(op: .screen, args: args, session: session), wait: 110))
    }

    /// Types into a macOS machine's screen; nil: its password, from the Keychain.
    func type(_ name: String, _ given: String?) throws {
        let text: String
        do { text = try given ?? Keychain.read("vm." + name) } catch {
            throw RPCError.internalError("\(name)'s password in the Keychain: \(error.localizedDescription)")
        }
        try screen(name, ["type", text], session: nil)   // the user's: no turn to wait for
    }

    private func makeMacFolder(_ m: VMMachine) throws {
        let password = (0..<24).map { _ in "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement().map(String.init) ?? "x" }.joined()
        try Keychain.set(password, account: "vm." + m.name)
        let pw = file(m.name, "password")
        guard FileManager.default.createFile(atPath: pw.path, contents: Data(password.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw RPCError.internalError("can't write \(pw.path)")
        }
        try run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "kelp-vm-" + m.name, "-f", file(m.name, "id_ed25519").path])
        try VMs.sshConfig(m, folder: folder(m.name)).write(to: file(m.name, "ssh_config"), atomically: true, encoding: .utf8)
    }

    /// Over SSH with the password once (ssh's SSH_ASKPASS reads the file): Kelp's key, then sudo without a password, a
    /// display and a Mac that never sleep (an agent's screenshot of a black screen says nothing). The file goes then.
    private func letKelpIn(_ m: VMMachine) throws {
        let askpass = file(m.name, "askpass")
        try "#!/bin/sh\ncat \(VMs.shellQuoted(file(m.name, "password").path))\n".write(to: askpass, atomically: true, encoding: .utf8)
        chmod(askpass.path, 0o700)
        defer { remove(askpass) }
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = askpass.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        let ssh = ["/usr/bin/ssh", "-F", file(m.name, "ssh_config").path, "-T", "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1", m.name]
        let key = try String(contentsOf: file(m.name, "id_ed25519.pub"), encoding: .utf8)
        let line = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        let keyed = try Subprocess.run(ssh + [line], cwd: "/", env: env, stdin: Data(key.utf8), timeLimit: 60)
        guard keyed.status == 0 else { throw RPCError.internalError("ssh with the password: " + String(decoding: keyed.stderr, as: UTF8.self)) }
        let password = try String(contentsOf: file(m.name, "password"), encoding: .utf8)
        let rule = "\(m.user) ALL=(ALL) NOPASSWD: ALL"
        let root = "echo \(VMs.shellQuoted(rule)) > /etc/sudoers.d/kelp && chmod 440 /etc/sudoers.d/kelp && pmset -a sleep 0 displaysleep 0 disksleep 0 && sync"
            + " && systemsetup -settimezone \(VMs.shellQuoted(TimeZone.current.identifier)) >/dev/null"   // the Mac's: times read the same
        let sudo = try Subprocess.run(["/usr/bin/ssh", "-F", file(m.name, "ssh_config").path, "-T", m.name,
                                       "sudo -S -p '' sh -c \(VMs.shellQuoted(root))"],
                                      cwd: "/", env: ProcessInfo.processInfo.environment, stdin: Data((password + "\n").utf8), timeLimit: 60)
        guard sudo.status == 0 else { throw RPCError.internalError("sudo: " + String(decoding: sudo.stderr, as: UTF8.self)) }
        // A screen that never locks: macOS locks it 5 minutes after the display sleeps, and then asks for this password. A
        // user's setting, so as the user (sysadminctl wants the password); then all of it written to the machine's disk.
        let unlock = "read -r pw; sysadminctl -screenLock off -password \"$pw\" && defaults -currentHost write com.apple.screensaver idleTime 0 && sync"
        let unlocked = try Subprocess.run(["/usr/bin/ssh", "-F", file(m.name, "ssh_config").path, "-T", m.name, unlock],
                                          cwd: "/", env: ProcessInfo.processInfo.environment, stdin: Data((password + "\n").utf8), timeLimit: 60)
        guard unlocked.status == 0 else { throw RPCError.internalError("screen lock: " + String(decoding: unlocked.stderr, as: UTF8.self)) }
        remove(file(m.name, "password"))
    }

    /// Kelp Guest, as an app in the machine's ~/Applications, started at login (a LaunchAgent in its GUI session): its
    /// apps' controls by name (`kelp vm ui`), with Accessibility, asked for the first time that runs. The screen needs it not.
    private func installGuest(_ m: VMMachine) throws {
        let bin = URL(fileURLWithPath: helper).deletingLastPathComponent().appendingPathComponent("KelpGuest")
        let work = file(m.name, ".guest"), app = work.appendingPathComponent("KelpGuest.app/Contents")
        remove(work)
        defer { remove(work) }
        try Paths.ensure(app.appendingPathComponent("MacOS"))
        try FileManager.default.copyItem(at: bin, to: app.appendingPathComponent("MacOS/KelpGuest"))
        let info: [String: Any] = ["CFBundleIdentifier": "dev.kelp.guest", "CFBundleName": "Kelp Guest", "CFBundleExecutable": "KelpGuest",
                                   "CFBundlePackageType": "APPL", "LSUIElement": true, "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "dev.kelp.guest", work.appendingPathComponent("KelpGuest.app").path])
        let tar = try Subprocess.run(["/usr/bin/tar", "-C", work.path, "-cf", "-", "KelpGuest.app"], cwd: "/", env: [:], timeLimit: 60, limit: 256 << 20)
        guard tar.status == 0 else { throw RPCError.internalError("tar: " + String(decoding: tar.stderr, as: UTF8.self)) }
        let home = "/Users/\(m.user)"
        let agent: [String: Any] = ["Label": "dev.kelp.guest", "ProgramArguments": ["\(home)/Applications/KelpGuest.app/Contents/MacOS/KelpGuest"],
                                    "RunAtLoad": true, "KeepAlive": true, "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive"]
        let plist = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
        let ssh = ["/usr/bin/ssh", "-F", file(m.name, "ssh_config").path, "-T", m.name]
        let env = ProcessInfo.processInfo.environment
        let unpack = "rm -rf ~/Applications/KelpGuest.app && mkdir -p ~/Applications ~/Library/LaunchAgents && tar -C ~/Applications -xf - && sync"
        let copied = try Subprocess.run(ssh + [unpack], cwd: "/", env: env, stdin: tar.stdout, timeLimit: 120)
        guard copied.status == 0 else { throw RPCError.internalError("copying Kelp Guest: " + String(decoding: copied.stderr, as: UTF8.self)) }
        let written = try Subprocess.run(ssh + ["cat > ~/Library/LaunchAgents/dev.kelp.guest.plist && sync"], cwd: "/", env: env, stdin: plist, timeLimit: 60)
        guard written.status == 0 else { throw RPCError.internalError("Kelp Guest's login item: " + String(decoding: written.stderr, as: UTF8.self)) }
        // Loaded now if the guest's login session is up; a first boot's may still be on its way (launchctl: "Domain does not
        // support specified action"), and then it starts at that login by itself: tried for two minutes, never a failure.
        let load = "launchctl bootout gui/$(id -u)/dev.kelp.guest 2>/dev/null; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.kelp.guest.plist"
        for _ in 0..<24 {
            let started = try Subprocess.run(ssh + [load], cwd: "/", env: env, timeLimit: 60)
            if started.status == 0 { return }
            Log.vm.info("\(m.name): Kelp Guest not loaded yet: \(String(decoding: started.stderr, as: UTF8.self))")
            Thread.sleep(forTimeInterval: 5)
        }
    }

    /// curl, which goes on where it stopped (`-C -`); how far (0…1), every few seconds, from a thread of its own. A file
    /// still growing is another curl's (a kelpd before this one started it): waited for, not downloaded twice.
    private func download(_ url: String, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let part = file.appendingPathExtension("part")
        let head = try await blocking { try run(["/usr/bin/curl", "-fsIL", url], limit: 60) }
        let total = Self.contentLength(head)
        func size() -> Double { var st = stat(); return stat(part.path, &st) == 0 ? Double(st.st_size) : 0 }
        while true {   // another curl's, still writing
            let before = size()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            if size() == before { break }
            if total > 0 { progress(size() / total) }
        }
        let done = OSAllocatedUnfairLock(initialState: false)
        Thread.detachNewThread {
            while !done.withLock({ $0 }) {
                if total > 0 { progress(min(1, size() / total)) }
                Thread.sleep(forTimeInterval: 3)
            }
        }
        defer { done.withLock { $0 = true } }
        if total == 0 || size() < total {
            let curl = ["/usr/bin/curl", "-fsSL", "--retry", "5", "-C", "-", "-o", part.path, url]
            let out = try await Subprocess.run(curl, cwd: "/", env: [:], timeLimit: 6 * 3600)
            guard out.status == 0 else { throw RPCError.internalError("Downloading macOS: " + String(decoding: out.stderr, as: UTF8.self)) }
        }
        try FileManager.default.moveItem(at: part, to: file)
    }

    /// The last Content-Length of curl -I's headers (after redirects). Header lines end in CRLF, which Swift reads as one
    /// Character: split on newlines, not on "\n".
    static func contentLength(_ headers: String) -> Double {
        let line = headers.components(separatedBy: .newlines).last { $0.lowercased().hasPrefix("content-length:") }
        return line.flatMap { Double($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
    }
}
