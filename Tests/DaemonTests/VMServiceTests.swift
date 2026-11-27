import Agents
import Core
import Foundation
import TestSupport
import Testing
import os

@testable import Daemon

/// What Kelp's machines read as from their folders alone: no kelp-vm runs in these.
@Suite struct VMServiceTests {
    let home = tmp().appendingPathComponent(
        "kvms-\(UUID().uuidString.prefix(6))")
    var vms: VMService { VMService(home: home, helper: "/nonexistent/kelp-vm") }
    let m = VMMachine(name: "deb", image: "debian-13", cpus: 2, memoryMiB: 2048, diskGiB: 32, user: "niko")

    private func folder(_ files: [String: String], modified: Date? = nil) throws {
        let f = home.appendingPathComponent("vms/deb")
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try JSONEncoder().encode(m).write(to: f.appendingPathComponent("machine.json"))
        for (name, text) in files {
            let u = f.appendingPathComponent(name)
            try Data(text.utf8).write(to: u)
            if let modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: u.path)
            }
        }
    }

    @Test func noFolderNoMachines() { #expect(vms.list().isEmpty) }

    /// A machine the user deletes goes to the Trash, its disk with it (`KELP_TRASH` in tests).
    @Test func aDeletedMachineGoesToTheTrash() throws {
        let work = "work \(UUID())"   // this test's own, among every test's in the Trash
        try folder(["disk.img": work])
        try vms.discard("deb", trash: true)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("vms/deb").path))
        #expect(inTheTrash("deb/disk.img", holding: work))
    }

    /// One deleted while it's being made (Stop Making) is gone for good, not to the Trash: half a machine is nobody's
    /// work. Its making then sees it gone at its next step, and its download stops there.
    @Test func oneStoppedWhileMadeIsGoneAndItsStepsSaySo() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let half = "half \(UUID())"
        try folder(["creating": String(decoding: VMMaking(step: .downloading).data, as: UTF8.self), "disk.img": half])
        #expect(vms.step(m, .downloading, progress: 0.5))
        _ = try vms.control("deb", .delete)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("vms/deb").path))
        #expect(!vms.step(m, .downloading, progress: 0.6))
        #expect(!inTheTrash("deb/disk.img", holding: half))
    }

    /// Deleted while it's made and made again under its name: the first making's next step finds another machine there
    /// and stops, rather than going on in the new one's folder.
    @Test func aMachineMadeAgainUnderItsNameStopsTheFirstMaking() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        var first = m, second = m
        first.made = "first"
        second.made = "second"
        let f = home.appendingPathComponent("vms/deb")
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try JSONEncoder().encode(first).write(to: f.appendingPathComponent("machine.json"))
        #expect(vms.step(first, .unpacking))
        try JSONEncoder().encode(second).write(to: f.appendingPathComponent("machine.json"))
        #expect(vms.deleted(first))
        #expect(!vms.step(first, .disk))
        #expect(throws: CancellationError.self) { try vms.next(first, .disk) }
        #expect(vms.step(second, .disk))
    }

    /// One machine alone wakes at any size it may be given (up to half the Mac's): the quarter is for them together.
    @Test func aMachineAloneWakesWhateverItsSize() throws {
        let half = Int(ProcessInfo.processInfo.physicalMemory >> 20) / 2
        let big = VMMachine(name: "big", image: "debian-13", cpus: 2, memoryMiB: half, diskGiB: 32, user: "niko")
        #expect(throws: Never.self) { try vms.admit(big) }
    }

    /// What made `dev` before a restart is found by its folder, not what runs in `dev2` beside it.
    @Test func leftoversAreFoundByTheWholeFolder() throws {
        let r = try NSRegularExpression(pattern: VMService.inFolder("/k/vms/dev"))
        func hits(_ line: String) -> Bool {
            r.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        #expect(
            hits("curl -o /k/vms/dev/disk.img.part https://x") && hits("installer /k/vms/dev") && hits("x /k/vms/dev y")
        )
        #expect(!hits("kelp-vm /k/vms/dev2") && !hits("ssh -F /k/vms/dev2/ssh_config dev2"))
    }

    /// What a killed kelp-vm left (an emulator, which names its AVD in its environment, not its arguments) is ended
    /// before the machine is made again or deleted midway: found by the pid it noted.
    @Test func leftoversIncludeANotedEmulator() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try folder([:])
        let child = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"])
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        let start = try #require(Subprocess.started(child.processIdentifier))
        try "\(child.processIdentifier) \(start)".write(
            to: vms.folder("deb").child("emulator"), atomically: true, encoding: .utf8)
        vms.endLeftovers("deb")
        #expect(try await waitFor(3) { !child.isRunning })
    }

    /// A made machine deleted, or stopped, after its kelp-vm was killed: the emulator it left ends too.
    @Test func aDeleteOrStopEndsWhatAKilledKelpVMLeft() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        for action in [VMControl.Action.stop, .delete] {
            try folder([:])
            let child = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"])
            defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
            let start = try #require(Subprocess.started(child.processIdentifier))
            try "\(child.processIdentifier) \(start)".write(
                to: vms.folder("deb").child("emulator"), atomically: true, encoding: .utf8)
            _ = try vms.control("deb", action)
            #expect(try await waitFor(3) { !child.isRunning }, "\(action)")
        }
    }

    /// Try Again twice (the user's, or the user's and an agent's) makes it again once: the first claims it before the
    /// seconds `makeAgain` spends ending what's left, and the second is answered as it's being made.
    @Test func aSecondTryAgainFindsItBeingMade() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        // of an image there isn't: made again, nothing is downloaded
        let nope = VMMachine(name: "deb", image: "nope", cpus: 2, memoryMiB: 2048, diskGiB: 32, user: "niko")
        try folder(["failed": "no disk"])
        try JSONEncoder().encode(nope).write(to: vms.folder("deb").machine)
        #expect(vms.claimRemake(nope))
        #expect(!vms.claimRemake(nope), "claimed already")
        #expect(try vms.create(VMCreate(name: "deb")).state == .creating)
    }

    /// A sleep counts as memory freed only once the machine says it's down.
    @Test func aSleepFreesOnlyAMachineThatsDown() throws {
        #expect(try vms.asleep(VMHelper.Reply(state: .sleeping, connections: 0)))
        #expect(try vms.asleep(VMHelper.Reply(state: .off, connections: 0)))
        #expect(try !vms.asleep(VMHelper.Reply(state: .starting, connections: 0)))
        #expect(try !vms.asleep(VMHelper.Reply(state: .running, connections: 0)))
        #expect(throws: (any Error).self) {
            try vms.asleep(VMHelper.Reply(state: .paused, connections: 0, error: "save failed"))
        }
    }

    @Test func aMachineBeingMadeSaysHowFarAndAStaleOneReadsAsFailed() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try folder(["creating": "Downloading Debian 13: 40%"])
        #expect(vms.list().map(\.state) == [.creating])
        #expect(vms.list().first?.detail == "Downloading Debian 13: 40%")
        try folder(["creating": "Making its disk"], modified: Date().addingTimeInterval(-3600))   // kelpd ended midway
        #expect(vms.list().map(\.state) == [.error])
        #expect(throws: RPCError.self) { try vms.connect("deb", cwd: nil) }
    }

    /// What `step()` writes now: a step and how far, read back as the machine's state.
    @Test func aMakingsStepAndProgressAreReadBack() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try folder(["creating": String(decoding: VMMaking(step: .downloading, progress: 0.4).data, as: UTF8.self)])
        let v = try #require(vms.list().first)
        #expect(v.state == .creating && v.step == .downloading && v.progress == 0.4)
    }

    @Test func aFailedOneSaysWhyAndCanBeDeleted() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try folder(["failed": "tar: broken"])
        #expect(vms.list().first.map { ($0.state, $0.detail) }! == (.error, "tar: broken"))
        _ = try vms.control("deb", .delete)
        #expect(vms.list().isEmpty)
    }

    /// One whose making failed reads as not made (one whose start failed reads as made); asked for again by its name
    /// alone, it's made again as it was: here from a raw disk of the user's that's gone, so it fails again, saying why.
    @Test func aFailedOneIsMadeAgainByItsNameAlone() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try folder(["failed": "tar: broken", "source": "/nonexistent/disk.raw"])
        #expect(vms.list().first?.notMade == true)
        #expect(try vms.create(VMCreate(name: "deb")).state == .creating)
        #expect(try await waitFor(5) { vms.list().first?.state == .error })
        let again = vms.list().first
        #expect(again?.notMade == true && again?.detail != "tar: broken")
    }

    /// A new machine reads as being made from its first answer, its step in its folder for a kelpd after this one to go
    /// on from: here from a raw disk of the user's, so it fails at its start (no kelp-vm), saying why.
    @Test func aNewMachineIsBeingMadeFromItsFirstAnswer() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let raw = home.appendingPathComponent("own.raw")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: raw)
        let made = try vms.create(VMCreate(name: "deb", image: "linux", file: raw.path))
        #expect(made.state == .creating)
        #expect(try await waitFor(60) { vms.list().first?.state == .error })
    }

    /// With no kelp-vm to ask, an Android machine is asleep while its emulator's snapshot is kept, as a Linux one is
    /// while its saved state is; shutting it down then forgets that snapshot, and the next start boots afresh.
    @Test func anAndroidMachineSleepsInItsSnapshotUntilItsShutDown() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let phone = VMMachine(
            name: "phone", os: "android", image: "android", cpus: 2, memoryMiB: 2048, diskGiB: 8, user: "niko")
        let f = vms.folder("phone"), snapshot = f.snapshot("phone")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try JSONEncoder().encode(phone).write(to: f.machine)
        #expect(vms.list().map(\.state) == [.sleeping])
        #expect(try vms.control("phone", .stop).state == .off)
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
    }

    /// An agent driving a macOS machine's screen runs nothing in it, and still works with it: the session whose turn the
    /// screen is counts (the sidebar names it).
    @Test func whoseTurnTheScreenIsCountsAsWorkingInIt() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let f = home.appendingPathComponent("vms/mac")
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let mac = VMMachine(
            name: "mac", os: "macos", image: "macos", cpus: 4, memoryMiB: 6144, diskGiB: 64, user: "niko")
        try JSONEncoder().encode(mac).write(to: f.appendingPathComponent("machine.json"))
        let server = try Unix.listen(f.appendingPathComponent("ctl.sock").path)
        defer { close(server) }
        Thread.detachNewThread {   // kelp-vm: a status, the screen's turn with "S1"
            while case let fd = accept(server, nil, nil), fd >= 0 {
                var b = [UInt8](repeating: 0, count: 4096)
                _ = read(fd, &b, b.count)
                _ = Unix.writeAll(fd, Data(#"{"state":"running","connections":0,"screen":"S1"}"#.utf8 + [10]))
                close(fd)
            }
        }
        #expect(vms.list().first?.sessions == nil)   // not asked for
        #expect(vms.list(sessions: true).first?.sessions == ["S1"])
    }

    /// In Kelp.app kelp-vm is an app of its own (its window has its own name in the Dock and ⌘Tab); in a build folder it's
    /// beside kelpd.
    @Test func kelpVMIsItsOwnAppInKelpAndBesideKelpdInABuild() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let macOS = home.appendingPathComponent("Kelp.app/Contents/MacOS"),
            kelpd = macOS.appendingPathComponent("kelpd").path
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        #expect(VMService.helper(beside: kelpd) == macOS.appendingPathComponent("kelp-vm").path)
        let inApp = home.appendingPathComponent("Kelp.app/Contents/Helpers/Kelp Machine.app/Contents/MacOS/kelp-vm")
        try FileManager.default.createDirectory(
            at: inApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: inApp.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        #expect(VMService.helper(beside: kelpd) == inApp.path)
    }

    /// A kelpd that won't get the home (another one runs it) doesn't touch a machine being made: only one that started
    /// makes machines a kelpd before it left midway.
    @Test func aKelpdThatDoesntStartLeavesMakingsAlone() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try folder(["creating": #"{"step":"downloading"}"#, "disk.img": "half"])
        _ = try Daemon(root: home)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("vms/deb/disk.img").path))
    }

    /// Whose turn a macOS machine's screen is goes by the session the caller's process is in, not by what it sends: an
    /// agent can't click in another's turn by naming the user, or nobody.
    @Test func theScreensTurnIsTheCallersSession() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let f = home.appendingPathComponent("vms/mac")
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let mac = VMMachine(
            name: "mac", os: "macos", image: "macos", cpus: 4, memoryMiB: 6144, diskGiB: 64, user: "niko")
        try JSONEncoder().encode(mac).write(to: f.appendingPathComponent("machine.json"))
        let server = try Unix.listen(f.appendingPathComponent("ctl.sock").path)
        let lock = open(f.appendingPathComponent("kelp-vm.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)   // as a kelp-vm holds it while it runs (`VMService.alive`)
        defer {
            close(server)
            close(lock)
        }
        let heard = OSAllocatedUnfairLock(initialState: [String]())
        Thread.detachNewThread {   // kelp-vm: running, and what it was asked
            while case let fd = accept(server, nil, nil), fd >= 0 {
                var b = [UInt8](repeating: 0, count: 4096)
                let n = read(fd, &b, b.count)
                let line = n > 0 ? String(decoding: b[0..<n], as: UTF8.self) : ""
                heard.withLock { $0.append(line) }
                _ = Unix.writeAll(fd, Data(#"{"state":"running","connections":0}"#.utf8 + [10]))
                close(fd)
            }
        }
        let vms = self.vms
        try Sessions.$asker.withValue("AGENT") {
            _ = try VMScreen(name: "mac", args: ["click", "1", "1"], session: nil).handle(vms)
        }
        try Sessions.$asker.withValue("AGENT") { _ = try VMType(name: "mac", text: "x").handle(vms) }
        let screens = heard.withLock { $0 }.filter { $0.contains(#""op":"screen""#) }
        #expect(screens.count == 2 && screens.allSatisfy { $0.contains(#""session":"AGENT""#) })
    }

    /// An Android machine's screen is the daemon's to drive, as a macOS one's is: taps and its controls go through adb
    /// to the emulator its kelp-vm names, not from the CLI's process.
    @Test func anAndroidMachinesScreenGoesThroughAdbFromTheDaemon() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let phone = VMMachine(
            name: "phone", os: "android", image: "android", cpus: 2, memoryMiB: 2048, diskGiB: 8, user: "niko")
        let f = vms.folder("phone"), sdk = home.appendingPathComponent("sdk")
        try FileManager.default.createDirectory(at: f.url, withIntermediateDirectories: true)
        try JSONEncoder().encode(phone).write(to: f.machine)
        let asked = sdk.appendingPathComponent("adb.log").path
        let screen = #"<hierarchy><node text="OK" clickable="true" bounds="[0,0][100,50]"/></hierarchy>"#
        try script(sdk.appendingPathComponent("emulator/emulator"), "exit 0")
        try script(
            sdk.appendingPathComponent("platform-tools/adb"),
            "echo \"$*\" >> '\(asked)'; case \"$*\" in *uiautomator*) echo '\(screen)' ;; esac")
        var vms = vms
        vms.androidSDK = { sdk }
        let server = try Unix.listen(f.control.path)
        let lock = open(f.lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)   // as a kelp-vm holds it while it runs
        defer {
            close(server)
            close(lock)
        }
        Thread.detachNewThread {   // kelp-vm: running, its emulator's serial
            while case let fd = accept(server, nil, nil), fd >= 0 {
                var b = [UInt8](repeating: 0, count: 4096)
                _ = read(fd, &b, b.count)
                _ = Unix.writeAll(
                    fd, Data(#"{"state":"running","connections":0,"serial":"emulator-5600"}"#.utf8 + [10]))
                close(fd)
            }
        }
        _ = try VMScreen(name: "phone", args: ["click", "10", "20"]).handle(vms)
        #expect(try VMUI(name: "phone").handle(vms).contains(#""OK" [ref=e1]"#))
        #expect(try String(contentsOfFile: asked, encoding: .utf8).contains("-s emulator-5600 shell input tap 10 20"))
        #expect(throws: RPCError.self) { try VMScreen(name: "phone", args: ["click", "ten", "20"]).handle(vms) }
    }

    private func script(_ url: URL, _ body: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A kelp-vm runs while it holds its machine's lock, answering or not: a busy one isn't taken for gone (a delete
    /// would take the folder from under it).
    @Test func aKelpVMIsAliveByItsLockNotItsAnswer() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try folder([:])
        #expect(!vms.alive("deb"))
        let lock = open(home.appendingPathComponent("vms/deb/kelp-vm.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        #expect(vms.alive("deb"))
        var vms = vms
        vms.quitPatience = 0.3
        await expectRefusal(says: "didn't stop") { _ = try vms.control("deb", .delete) }   // it doesn't answer, it's there: kept
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("vms/deb/machine.json").path))
        close(lock)
        #expect(!vms.alive("deb"))
    }

    /// A kelp-vm that holds its lock and doesn't quit (stuck in Virtualization) is killed by the pid it noted, so the
    /// machine can be deleted without restarting the Mac.
    @Test func aKelpVMThatWontQuitIsKilledByItsNote() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try folder([:])
        let lock = home.appendingPathComponent("vms/deb/kelp-vm.lock").path
        let stuck = try Process.run(
            URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "use Fcntl ':flock'; open(F, '>>', $ARGV[0]); flock(F, LOCK_EX); sleep 60", lock])
        defer { if stuck.isRunning { kill(stuck.processIdentifier, SIGKILL) } }
        #expect(try await waitFor(5) { vms.alive("deb") })
        let start = try #require(Subprocess.started(stuck.processIdentifier))
        try "\(stuck.processIdentifier) \(start)".write(
            to: vms.folder("deb").child(VMFolder.helperNote), atomically: true, encoding: .utf8)
        var vms = vms
        vms.quitPatience = 0.3
        vms.quit("deb")
        #expect(!vms.alive("deb"))
        #expect(try await waitFor(3) { !stuck.isRunning })
    }

    /// A disk grown before machine.json could be written says a smaller size there: a later grow to less than the file
    /// is leaves it as it is, never cut back under what's on it.
    @Test func aDiskIsNeverCutBackByAnOlderSize() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try folder([:])
        let disk = vms.folder("deb").disk.path
        FileManager.default.createFile(atPath: disk, contents: nil)
        #expect(truncate(disk, 40 << 30) == 0)   // grown to 40 GB; machine.json still says 32
        func size() throws -> Int64? {
            (try FileManager.default.attributesOfItem(atPath: disk)[.size] as? NSNumber)?.int64Value
        }
        _ = try vms.configure(VMConfigure(name: "deb", disk: 36))
        #expect(try size() == 40 << 30)
        _ = try vms.configure(VMConfigure(name: "deb", disk: 48))
        #expect(try size() == 48 << 30)
    }

    @Test func offOrAsleepFromItsFolderWithoutItsProcess() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try folder([:])
        #expect(vms.list().map(\.state) == [.off] && vms.list().first?.notMade == nil)
        try folder(["state.vzsave": "x"])
        #expect(vms.list().map(\.state) == [.sleeping])
    }

    @Test func namesAndImagesAreChecked() async {
        await expectRefusal(says: "A machine's name") { try vms.create(VMCreate(name: "Bad Name")) }
        await expectRefusal(says: "No image windows") { try vms.create(VMCreate(name: "ok", image: "windows")) }
        #expect(throws: RPCError.self) { try vms.machine("nope") }
    }

    /// Agents run commands in machines; making one, shutting it down or deleting it is the user's.
    @Test func whatAgentsMayNotDo() {
        #expect(VMControl(name: "x", action: .stop).fence.notForAgents != nil)
        #expect(VMControl(name: "x", action: .delete).fence.notForAgents != nil)
        #expect(VMControl(name: "x", action: .sleep).fence.notForAgents == nil)
        #expect(VMControl(name: "x", action: .start).fence.notForAgents == nil)
    }
}

/// simctl's list isn't in age order: the plain iPhone with the highest number, on the newest iOS.
@Test func theNewestIPhoneOnTheNewestIOS() throws {
    let json = """
        {"runtimes": [
          {"identifier": "iOS-26-0", "platform": "iOS", "version": "26.0", "isAvailable": true, "supportedDeviceTypes": []},
          {"identifier": "iOS-27-0", "platform": "iOS", "version": "27.0", "isAvailable": true, "supportedDeviceTypes": [
            {"identifier": "iPhone-17", "name": "iPhone 17", "productFamily": "iPhone"},
            {"identifier": "iPhone-11", "name": "iPhone 11", "productFamily": "iPhone"},
            {"identifier": "iPhone-17-Pro", "name": "iPhone 17 Pro", "productFamily": "iPhone"},
            {"identifier": "iPad-Air", "name": "iPad Air", "productFamily": "iPad"}]},
          {"identifier": "watchOS-12", "platform": "watchOS", "version": "12.0", "isAvailable": true}]}
        """
    let pick = try VMService.newestIPhone(json)
    #expect(pick.runtime == "iOS-27-0" && pick.device == "iPhone-17")
}

/// A file to make a machine from is looked at first: what can't run is refused, saying what to do.
@Test func aMachinesFileIsCheckedFirst() async throws {
    let dir = tmp().appendingPathComponent("kvmf-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let linux = try #require(VMImage.named("linux")), mac = try #require(VMImage.named("macos")),
        android = try #require(VMImage.named("android"))
    let qcow = dir.appendingPathComponent("a.qcow2"), iso = dir.appendingPathComponent("a.iso"),
        raw = dir.appendingPathComponent("a.raw")
    try Data([0x51, 0x46, 0x49, 0xFB, 0, 0, 0, 3]).write(to: qcow)
    var isoBytes = Data(count: 0x8006)
    isoBytes.replaceSubrange(0x8001..<0x8006, with: Data("CD001".utf8))
    try isoBytes.write(to: iso)
    try Data(count: 4096).write(to: raw)
    await expectRefusal(says: "qcow2 image") { try VMService.check(qcow, for: linux) }
    await expectRefusal(says: "installer ISO") { try VMService.check(iso, for: linux) }
    await expectRefusal(says: "restore image (.ipsw)") { try VMService.check(raw, for: mac) }   // not an .ipsw
    await expectRefusal(says: "Android machines come from your SDK") { try VMService.check(raw, for: android) }
    await expectRefusal(says: "No file") { try VMService.check(dir.appendingPathComponent("gone.raw"), for: linux) }
    try VMService.check(raw, for: linux)
}

/// curl -I's header lines end in CRLF, one Character to Swift: the length is still found, the last one after redirects.
@Test func aDownloadsLengthIsReadFromCRLFHeaders() {
    let headers =
        "HTTP/1.1 302 Found\r\nContent-Length: 0\r\nLocation: x\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 25595669503\r\n\r\n"
    #expect(VMService.contentLength(headers) == 25_595_669_503)
    #expect(VMService.contentLength("HTTP/1.1 200 OK\r\n\r\n") == 0)
}

/// Through the daemon, by a machine's folder alone (no kelp-vm runs): listed, nothing read from inside one that's off,
/// resized while it's off (a disk only grows), and one that failed or isn't there can't be connected to.
@Test func machinesAreListedAndResizedFromTheirFolders() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let folder = d.root.appendingPathComponent("vms/deb")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let machine = VMMachine(name: "deb", image: "debian-13", cpus: 2, memoryMiB: 2048, diskGiB: 32, user: "t")
    try JSONEncoder().encode(machine).write(to: folder.appendingPathComponent("machine.json"))
    #expect(try await c.call(VMList()).map(\.state) == [.off])
    #expect(try await c.call(VMDetailRead(name: "deb")) == nil)   // only a running one is read from inside
    #expect(try await c.call(VMConfigure(name: "deb", cpus: 1)).machine.cpus == 1)
    #expect(try await c.call(VMList()).first?.machine.cpus == 1)   // kept in its folder
    await #expect(throws: (any Error).self) { _ = try await c.call(VMConfigure(name: "deb", disk: 8)) }
    try Data("tar: broken".utf8).write(to: folder.appendingPathComponent("failed"))
    await #expect(throws: (any Error).self) { _ = try await c.call(VMConnect(name: "deb", cwd: nil)) }
    await #expect(throws: (any Error).self) { _ = try await c.call(VMConnect(name: "none", cwd: nil)) }
    await #expect(throws: (any Error).self) { _ = try await c.call(VMControl(name: "none", action: .sleep)) }
}

/// An agent's vm.create asks the user on its row first (as a database change does): Deny refuses it, Allow goes on to
/// make it (here from an image there isn't, so making it fails at once, past the question). A name that can't be a
/// machine's isn't asked about.
@Test func anAgentsMachineIsMadeOnlyOnceTheUserAllowsIt() async throws {
    let bot = AgentManifest(id: "bot", name: "Bot", command: "/bin/sh", args: ["-c", "cat"])
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let asking = VMAsking.of(w.d)
    func ask(_ name: String, image: String? = nil) -> Task<VMInfo, Error> {
        Task {
            try await Sessions.$asker.withValue(agent.id) {
                try await VMCreate(name: name, image: image).handle(asking, conn: -1)
            }
        }
    }
    func summary() throws -> String { try w.d.store.session(agent.id)?.summary ?? "" }
    let denied = ask("deb")
    #expect(try await waitFor { try summary() == "Allow making a machine, deb (Debian 13: about 0.2 GB to download)?" })
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "deny", question: try summary())))
    await expectRefusal(says: "didn't allow making deb") { try await denied.value }
    #expect(VMService(home: w.d.root, helper: "").list().isEmpty)
    await expectRefusal(says: "A machine's name") { try await ask("Not_A_Name").value }
    // The row lets go of the denied question on the session's status queue, after the refusal is thrown.
    #expect(try await waitFor { try summary().isEmpty })
    let allowed = ask("box", image: "nope")
    #expect(try await waitFor { try summary().hasPrefix("Allow making a machine, box") })
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: try summary())))
    do {
        _ = try await allowed.value
        Issue.record("a machine of an image there isn't was made")
    } catch { #expect((error as? RPCError)?.message.hasPrefix("No image nope") == true) }
}
