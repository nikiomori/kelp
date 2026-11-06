import Foundation
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
                step(m, "Asking Apple for the latest macOS")
                let latest = try await blocking { try run([helper, "--latest"], limit: 120) }
                struct Latest: Decodable { var url: String, build: String, version: String }
                let l = try JSONDecoder().decode(Latest.self, from: Data(latest.utf8))
                try Paths.ensure(images)
                ipsw = images.appendingPathComponent("macos-\(l.build).ipsw")
                version = "macOS \(l.version)"
                if !FileManager.default.fileExists(atPath: ipsw.path) {
                    let title = version
                    try await download(l.url, to: ipsw) { step(m, "Downloading \(title): \($0)") }
                }
            }
            try await blocking { try makeMacFolder(m) }
            step(m, "Installing \(version)")
            let image = ipsw
            try await blocking { _ = try run([helper, "--install", folder(m.name).path, image.path], limit: 3600) }
            if given == nil { remove(ipsw) }   // ours, and over 20 GB: the user's own stays
            step(m, "Setting macOS up: its first boot takes a few minutes")
            try await blocking { try startHelper(m); try check(ask(m.name, .init(op: .start), wait: 1800)) }
            step(m, "Letting Kelp in")
            try await blocking { try letKelpIn(m); try installGuest(m) }
        }
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
        let root = "echo \(VMs.shellQuoted(rule)) > /etc/sudoers.d/kelp && chmod 440 /etc/sudoers.d/kelp && pmset -a sleep 0 displaysleep 0 disksleep 0"
            + " && systemsetup -settimezone \(VMs.shellQuoted(TimeZone.current.identifier)) >/dev/null"   // the Mac's: times read the same
        let sudo = try Subprocess.run(["/usr/bin/ssh", "-F", file(m.name, "ssh_config").path, "-T", m.name,
                                       "sudo -S -p '' sh -c \(VMs.shellQuoted(root))"],
                                      cwd: "/", env: ProcessInfo.processInfo.environment, stdin: Data((password + "\n").utf8), timeLimit: 60)
        guard sudo.status == 0 else { throw RPCError.internalError("sudo: " + String(decoding: sudo.stderr, as: UTF8.self)) }
        remove(file(m.name, "password"))
    }

    /// Kelp Guest, as an app in the machine's ~/Applications, started at login (a LaunchAgent in its GUI session). It asks
    /// for Screen Recording and Accessibility there: the machine's window shows the switches.
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
        let unpack = "rm -rf ~/Applications/KelpGuest.app && mkdir -p ~/Applications ~/Library/LaunchAgents && tar -C ~/Applications -xf -"
        let copied = try Subprocess.run(ssh + [unpack], cwd: "/", env: env, stdin: tar.stdout, timeLimit: 120)
        guard copied.status == 0 else { throw RPCError.internalError("copying Kelp Guest: " + String(decoding: copied.stderr, as: UTF8.self)) }
        let load = "cat > ~/Library/LaunchAgents/dev.kelp.guest.plist && launchctl bootout gui/$(id -u)/dev.kelp.guest 2>/dev/null; "
            + "launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.kelp.guest.plist"
        let started = try Subprocess.run(ssh + [load], cwd: "/", env: env, stdin: plist, timeLimit: 60)
        guard started.status == 0 else { throw RPCError.internalError("starting Kelp Guest: " + String(decoding: started.stderr, as: UTF8.self)) }
    }

    /// curl, which goes on where it stopped (`-C -`); how far, in GB, every few seconds.
    private func download(_ url: String, to file: URL, progress: @escaping @Sendable (String) -> Void) async throws {
        let part = file.appendingPathExtension("part")
        let head = try await blocking { try run(["/usr/bin/curl", "-fsIL", url], limit: 60) }
        let total = head.split(separator: "\n").last { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Double($0.split(separator: ":")[1].trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let watch = Task {
            while !Task.isCancelled {
                var st = stat()
                if stat(part.path, &st) == 0, total > 0 {
                    progress(String(format: "%.1f of %.1f GB", Double(st.st_size) / 1e9, total / 1e9))
                }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        defer { watch.cancel() }
        let out = try await Subprocess.run(["/usr/bin/curl", "-fsSL", "--retry", "5", "-C", "-", "-o", part.path, url], cwd: "/", env: [:], timeLimit: 6 * 3600)
        guard out.status == 0 else { throw RPCError.internalError("Downloading macOS: " + String(decoding: out.stderr, as: UTF8.self)) }
        try FileManager.default.moveItem(at: part, to: file)
    }
}
