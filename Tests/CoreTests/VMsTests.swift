import Foundation
import Testing
@testable import Core

@Test func machineNamesAreShortLowercaseAndSafeInPaths() {
    for good in ["debian", "dev-2", "a"] { #expect(VMs.isName(good), "\(good)") }
    for bad in ["", "Debian", "2dev", "a.b", "a/b", "-x", "../x", String(repeating: "a", count: 21), "a b"] { #expect(!VMs.isName(bad), "\(bad)") }
}

@Test func theGuestAccountIsTheMacUsersNameWhenLinuxTakesIt() {
    #expect(VMs.user("nikimori") == "nikimori")
    #expect(VMs.user("Niko") == "kelp")
    #expect(VMs.user("root") == "kelp")
    #expect(VMs.user("1abc") == "kelp")
}

@Test func userDataHasTheKeyAndRosettaOnlyWhenAsked() {
    let m = VMMachine(name: "debian", image: "debian-13", cpus: 2, memoryMiB: 2048, diskGiB: 32, user: "niko")
    let s = VMs.userData(m, publicKey: "ssh-ed25519 AAAA kelp\n", timeZone: "Europe/Istanbul")
    #expect(s.hasPrefix("#cloud-config\n"))
    #expect(s.contains("      - ssh-ed25519 AAAA kelp\n"))
    #expect(s.contains("timezone: Europe/Istanbul"))
    #expect(s.contains(#":rosetta:M::\x7fELF\x02"#))   // backslashes as written: binfmt reads them, not YAML (a literal block)
    var plain = m; plain.rosetta = false
    #expect(!VMs.userData(plain, publicKey: "k", timeZone: "UTC").contains("rosetta"))
}

@Test func sshConfigReachesTheMachineOnlyThroughItsSockets() {
    let m = VMMachine(name: "debian", image: "debian-13", cpus: 2, memoryMiB: 2048, diskGiB: 32, user: "niko")
    let s = VMs.sshConfig(m, folder: URL(fileURLWithPath: "/Users/n/.kelp/vms/debian"))
    #expect(s.contains("Host debian\n") && s.contains("Host debian-own\n"))
    #expect(s.contains("ProxyCommand /usr/bin/nc -U '/Users/n/.kelp/vms/debian/ssh.sock'"))
    #expect(s.contains("ProxyCommand /usr/bin/nc -U '/Users/n/.kelp/vms/debian/own.sock'"))
    #expect(s.contains("IdentitiesOnly yes"))
}

/// The folder mounts at its own path and quotes survive: the line is valid shell.
@Test func theCommandPrefixMountsTheFolderAtItsOwnPath() throws {
    let p = VMs.prefix(slot: 3, folder: "/Users/n/it's a/app", cwd: "/Users/n/it's a/app/src")
    #expect(p.contains("mount --mkdir -t virtiofs kelp3 '/Users/n/it'\\''s a/app'"))
    #expect(p.contains("cd '/Users/n/it'\\''s a/app/src' || exit 1; "))
    let check = try Subprocess.run(["/bin/sh", "-n", "-c", p + "true"], cwd: "/", env: [:], timeLimit: 10)
    #expect(check.status == 0, "\(String(decoding: check.stderr, as: UTF8.self))")
}

@Test func theBalloonFollowsWhatTheGuestUses() {
    // A fresh 4 GiB guest using 300 MiB: keep 1.3 GiB.
    #expect(VMs.memoryTarget(totalMiB: 3950, availableMiB: 3650, targetMiB: 4096, machineMiB: 4096) == 1324)
    // The same guest with that balloon: no change.
    #expect(VMs.memoryTarget(totalMiB: 3950, availableMiB: 3650 - 2772, targetMiB: 1324, machineMiB: 4096) == 1324)
    // Running short: a GiB more at once.
    #expect(VMs.memoryTarget(totalMiB: 3950, availableMiB: 300, targetMiB: 1324, machineMiB: 4096) == 2348)
    // Never past the machine, never under 1 GiB.
    #expect(VMs.memoryTarget(totalMiB: 3950, availableMiB: 100, targetMiB: 3800, machineMiB: 4096) == 4096)
    #expect(VMs.memoryTarget(totalMiB: 1950, availableMiB: 1949, targetMiB: 2048, machineMiB: 2048) == 1025)
    #expect(VMs.memoryTarget(totalMiB: 1950, availableMiB: 1700, targetMiB: 1100, machineMiB: 2048) == 1100)   // under 256 apart
}

@Test func onlyFoldersInsideTheHomeFolderAreShared() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    #expect(VMs.mayShare(home + "/projects/app"))
    for bad in [home, home + "/", home + "/.ssh", home + "/.ssh/keys", home + "/Library/Keychains", home + "/../other", "/", "/etc", home + "/.kelp"] {
        #expect(!VMs.mayShare(bad), "\(bad)")
    }
}

/// A run carries the session it came from in its name; a shell has no command.
@Test func aRunIsMarkedWithItsSession() throws {
    #expect(VMs.command("npm test && ls", session: "AB-12") == "exec -a kelp-vm-run:AB-12 bash -l -c 'trap : EXIT; npm test && ls'")
    #expect(VMs.command("", session: nil) == "exec -a kelp-vm-run:- bash -l")
    #expect(VMs.command("x", session: "a;rm -rf ~") == "exec -a kelp-vm-run:arm-rf bash -l -c 'trap : EXIT; x'")   // only what an id holds
    let check = try Subprocess.run(["/bin/sh", "-n", "-c", VMs.command("echo 'it''s'", session: "x")], cwd: "/", env: [:], timeLimit: 10)
    #expect(check.status == 0)
}

@Test func whatRunsInsideIsReadBack() {
    let text = "192.168.64.7\n@\n3000\n5432\n@\n  812       00:41 kelp-vm-run:abc -l -c trap : EXIT; npm test --watch\n  901 1-02:00:07 kelp-vm-run:- -l\n"
    let d = VMs.parseDetail(text)
    #expect(d.address == "192.168.64.7")
    #expect(d.ports == [3000, 5432])
    #expect(d.runs == [.init(pid: 812, seconds: 41, session: "abc", command: "npm test --watch"),
                       .init(pid: 901, seconds: 93607, session: nil, command: "")])
    #expect(VMs.parseDetail("\n@\n@\n") == VMDetail())
    #expect(VMs.parseDetail("10.0.0.2\n@\n@\n  5 00:03 kelp-vm-run:x -l\n").runs.count == 1)   // no ports: two "@" in a row
    let mac = VMs.parseDetail("192.168.64.8\n@\n@\n@\nscreen recording: on\naccessibility: off\nscreen: abc\n")
    #expect(mac.guest == .init(running: true, screenRecording: true, accessibility: false, screen: "abc"))
    #expect(VMs.parseDetail("x\n@\n@\n@\nKelp Guest isn't running: open the machine's window and sign in.\nnot running\n").guest?.running == false)
}

/// On macOS the folder mounts with mount_virtiofs, and the line is still valid shell.
@Test func aMacOSPrefixUsesItsOwnMount() throws {
    let p = VMs.prefix(slot: 1, folder: "/Users/n/app", cwd: "/Users/n/app", os: "macos")
    #expect(p.contains("sudo mount_virtiofs kelp1 '/Users/n/app'") && p.contains("grep -qF 'kelp1 on /Users/n/app ('"))
    let check = try Subprocess.run(["/bin/sh", "-n", "-c", p + "true"], cwd: "/", env: [:], timeLimit: 10)
    #expect(check.status == 0)
}

@Test func anAndroidScreenReadsAsLinesWithRefs() {
    let xml = """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">\
        <node index="0" text="" class="android.widget.FrameLayout" clickable="false" bounds="[0,0][1080,2400]">\
        <node index="0" text="Sign in" resource-id="com.app:id/login" class="android.widget.Button" clickable="true" bounds="[96,1180][984,1312]"/>\
        <node index="1" text="" class="android.widget.EditText" clickable="true" bounds="[96,900][984,1020]"/>\
        </node></hierarchy>
        """
    let ui = AndroidSDK.ui(xml)
    #expect(ui.text == "- button \"Sign in\" #login [ref=e1] (96,1180 888×132)\n- edittext \"\" [ref=e2] (96,900 888×120)")
    #expect(ui.centers["e1"]! == (540, 1246))
    #expect(AndroidSDK.inputText("a b;$(x)") == #"a%sb\;\$\(x\)"#)
}

/// A macOS machine's screen types US keys from the Mac's side: letters, Shift for capitals and symbols, none for the rest.
@Test func aCharacterIsItsUSKey() {
    #expect(VMs.usKey("a")?.code == 0 && VMs.usKey("a")?.shift == false)
    #expect(VMs.usKey("A")?.code == 0 && VMs.usKey("A")?.shift == true)
    #expect(VMs.usKey("@")?.code == 19 && VMs.usKey("@")?.shift == true)
    #expect(VMs.usKey("\n")?.code == 36)
    #expect(VMs.usKey("ж") == nil && VMs.usKey("é") == nil)
}
