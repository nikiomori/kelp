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
