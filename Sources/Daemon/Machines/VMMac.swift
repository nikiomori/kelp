import Core
import Foundation
import os

/// Makes a macOS machine, which is what `VMService.create` does with the macos image.
extension VMService {
    /// Downloads Apple's latest macOS for this Mac and installs it, then deletes the download (it's 20 GB and more). On
    /// its first boot macOS sets itself up: an account with a random password (kept in the Keychain as "vm.<name>"),
    /// signed in, with Remote Login on. Then Kelp connects over SSH with that password once, to add Kelp's key, sudo
    /// without a password and a screen that never sleeps. With `given`, the user's own restore image is installed as it
    /// is and left where it is.
    func makeMac(_ machine: VMMachine, ipsw given: URL? = nil) async {
        await making(machine) {
            var ipsw = given ?? images, version = given?.deletingPathExtension().lastPathComponent ?? ""
            if given == nil {
                try next(machine, .asking)
                let latest = try await blocking { try run([helper, "--latest"], limit: 120) }
                struct Latest: Decodable { var url: String, build: String, version: String }
                let release = try JSONDecoder().decode(Latest.self, from: Data(latest.utf8))
                try Paths.ensure(images)
                ipsw = images.appendingPathComponent("macos-\(release.build).ipsw")
                version = "macOS \(release.version)"
                if !FileManager.default.fileExists(atPath: ipsw.path) {
                    let title = version
                    try await download(release.url, to: ipsw) { step(machine, .downloading, title, progress: $0) }
                }
            }
            try await blocking { try makeMacFolder(machine) }
            try next(machine, .installing, version)
            let image = ipsw
            try await blocking {
                _ = try run([helper, "--install", folder(machine.name).path, image.path], limit: 3600)
            }
            if given == nil { remove(ipsw) }   // Kelp's download (over 20 GB) goes; the user's own stays
            try next(machine, .firstBoot)
            try await blocking {
                try startHelper(machine)
                try check(ask(machine.name, .init(op: .start), wait: 1800))
            }
            try next(machine, .lettingIn)
            try await blocking {
                try letKelpIn(machine)
                try installGuest(machine)
            }
        }
    }

    private func makeMacFolder(_ machine: VMMachine) throws {
        let password = (0..<24).map { _ in
            "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement().map(String.init) ?? "x"
        }.joined()
        try Keychain.set(password, account: "vm." + machine.name)
        let pw = folder(machine.name).password
        guard
            FileManager.default.createFile(
                atPath: pw.path, contents: Data(password.utf8), attributes: [.posixPermissions: 0o600])
        else {
            throw RPCError.internalError("can't write \(pw.path)")
        }
        try run([
            "/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "kelp-vm-" + machine.name, "-f",
            folder(machine.name).key.path
        ])
        try VMs.sshConfig(machine, folder: folder(machine.name)).write(
            to: folder(machine.name).sshConfig, atomically: true, encoding: .utf8)
    }

    /// Connects over SSH with the password once (ssh's SSH_ASKPASS reads it from the password file) to add Kelp's
    /// key. Then it sets up sudo without a password, and a display and a Mac that never sleep, because an agent's
    /// screenshot of a black screen says nothing. The password file is deleted at the end.
    private func letKelpIn(_ machine: VMMachine) throws {
        let askpass = folder(machine.name).file("askpass")
        try "#!/bin/sh\ncat \(ShellQuote.word(folder(machine.name).password.path))\n".write(
            to: askpass, atomically: true, encoding: .utf8)
        chmod(askpass.path, 0o700)
        defer { remove(askpass) }
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = askpass.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        let ssh = [
            "/usr/bin/ssh", "-F", folder(machine.name).sshConfig.path, "-T", "-o", "PubkeyAuthentication=no", "-o",
            "NumberOfPasswordPrompts=1", machine.name
        ]
        let key = try String(contentsOf: folder(machine.name).key.appendingPathExtension("pub"), encoding: .utf8)
        let line =
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        try run(ssh + [line], "ssh with the password", env: env, stdin: Data(key.utf8))
        let password = try String(contentsOf: folder(machine.name).password, encoding: .utf8)
        let rule = "\(machine.user) ALL=(ALL) NOPASSWD: ALL"
        let root =
            "echo \(ShellQuote.word(rule)) > /etc/sudoers.d/kelp && chmod 440 /etc/sudoers.d/kelp && pmset -a sleep 0 displaysleep 0 disksleep 0 && sync"
            // The machine gets the Mac's time zone, so times read the same on both.
            + " && systemsetup -settimezone \(ShellQuote.word(TimeZone.current.identifier)) >/dev/null"
        let asUser = ["/usr/bin/ssh", "-F", folder(machine.name).sshConfig.path, "-T", machine.name]
        try run(
            asUser + ["sudo -S -p '' sh -c \(ShellQuote.word(root))"], "sudo", env: ProcessInfo.processInfo.environment,
            stdin: Data((password + "\n").utf8))
        // The screen must never lock, because macOS locks it 5 minutes after the display sleeps and then asks for this
        // password. That is a user's setting, so this runs as the user (sysadminctl wants the password). Then all of it
        // is synced to the machine's disk.
        let unlock =
            "read -r pw; sysadminctl -screenLock off -password \"$pw\" && defaults -currentHost write com.apple.screensaver idleTime 0"
            // This makes ~/Kelp, because on the machine's first boot kelp-vm had no key yet to make it.
            + " && { \(VMs.filesSetup(os: .macos)); } && sync"
        try run(
            asUser + [unlock], "screen lock", env: ProcessInfo.processInfo.environment,
            stdin: Data((password + "\n").utf8))
        remove(folder(machine.name).password)
    }

    /// Installs Kelp Guest as an app in the machine's ~/Applications, started at login by a LaunchAgent in the GUI
    /// session. Kelp Guest finds the controls of the machine's apps by name (`kelp vm ui`) through Accessibility, which
    /// macOS asks for the first time that runs. The screen itself doesn't need Kelp Guest.
    private func installGuest(_ machine: VMMachine) throws {
        let bin = URL(fileURLWithPath: helper).deletingLastPathComponent().appendingPathComponent("KelpGuest")
        let work = folder(machine.name).file(".guest"), app = work.appendingPathComponent("KelpGuest.app/Contents")
        remove(work)
        defer { remove(work) }
        try Paths.ensure(app.appendingPathComponent("MacOS"))
        try FileManager.default.copyItem(at: bin, to: app.appendingPathComponent("MacOS/KelpGuest"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.kelp.guest", "CFBundleName": "Kelp Guest", "CFBundleExecutable": "KelpGuest",
            "CFBundlePackageType": "APPL", "LSUIElement": true, "LSMinimumSystemVersion": "14.0"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
            to: app.appendingPathComponent("Info.plist"))
        try run([
            "/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "dev.kelp.guest",
            work.appendingPathComponent("KelpGuest.app").path
        ])
        let tar = try Subprocess.run(
            ["/usr/bin/tar", "-C", work.path, "-cf", "-", "KelpGuest.app"], cwd: "/", env: [:], timeLimit: 60,
            limit: 256 << 20)
        guard tar.status == 0 else {
            throw RPCError.internalError("tar: " + String(decoding: tar.stderr, as: UTF8.self))
        }
        let home = "/Users/\(machine.user)"
        let agent: [String: Any] = [
            "Label": "dev.kelp.guest",
            "ProgramArguments": ["\(home)/Applications/KelpGuest.app/Contents/MacOS/KelpGuest"],
            "RunAtLoad": true, "KeepAlive": true, "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive"
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
        let ssh = ["/usr/bin/ssh", "-F", folder(machine.name).sshConfig.path, "-T", machine.name]
        let env = ProcessInfo.processInfo.environment
        let unpack =
            "rm -rf ~/Applications/KelpGuest.app && mkdir -p ~/Applications ~/Library/LaunchAgents && tar -C ~/Applications -xf - && sync"
        try run(ssh + [unpack], "copying Kelp Guest", env: env, stdin: tar.stdout, limit: 120)
        try run(
            ssh + ["cat > ~/Library/LaunchAgents/dev.kelp.guest.plist && sync"], "Kelp Guest's login item", env: env,
            stdin: plist)
        // This loads now if the guest's login session is up. On a first boot the login may still be on its way
        // (launchctl says "Domain does not support specified action"), and then the agent starts by itself at that
        // login. Loading is tried for two minutes and never counts as a failure.
        let load =
            "launchctl bootout gui/$(id -u)/dev.kelp.guest 2>/dev/null; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.kelp.guest.plist"
        for _ in 0..<24 {
            let started = try Subprocess.run(ssh + [load], cwd: "/", env: env, timeLimit: 60)
            if started.status == 0 { return }
            Log.vm.info(
                "\(machine.name): Kelp Guest not loaded yet: \(String(decoding: started.stderr, as: UTF8.self))")
            Thread.sleep(forTimeInterval: 5)
        }
    }
}

extension VMService {
    /// Returns the path of kelp-vm. In Kelp.app it is an app of its own in Contents/Helpers, because a machine's screen
    /// is a kelp-vm window, with its own name in the Dock and ⌘Tab. In a build folder kelp-vm sits beside kelpd.
    /// KelpGuest sits beside kelp-vm either way.
    static func helper(beside kelpd: String) -> String {
        let dir = URL(fileURLWithPath: kelpd).deletingLastPathComponent()
        let app = dir.deletingLastPathComponent().appendingPathComponent(
            "Helpers/Kelp Machine.app/Contents/MacOS/kelp-vm")
        return FileManager.default.isExecutableFile(atPath: app.path)
            ? app.path : dir.appendingPathComponent("kelp-vm").path
    }
}
