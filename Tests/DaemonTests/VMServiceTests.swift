import Core
import Foundation
import Testing
@testable import Daemon

/// What Kelp's machines read as from their folders alone: no kelp-vm runs in these.
@Suite struct VMServiceTests {
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kvms-\(UUID().uuidString.prefix(6))")
    var vms: VMService { VMService(home: home, helper: "/nonexistent/kelp-vm") }
    let m = VMMachine(name: "deb", image: "debian-13", cpus: 2, memoryMiB: 2048, diskGiB: 32, user: "niko")

    private func folder(_ files: [String: String], modified: Date? = nil) throws {
        let f = home.appendingPathComponent("vms/deb")
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try JSONEncoder().encode(m).write(to: f.appendingPathComponent("machine.json"))
        for (name, text) in files {
            let u = f.appendingPathComponent(name)
            try Data(text.utf8).write(to: u)
            if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: u.path) }
        }
    }

    @Test func noFolderNoMachines() { #expect(vms.list().isEmpty) }

    @Test func aMachineBeingMadeSaysHowFarAndAStaleOneReadsAsFailed() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try folder(["creating": "Downloading Debian 13: 40%"])
        #expect(vms.list().map(\.state) == [.creating])
        #expect(vms.list().first?.detail == "Downloading Debian 13: 40%")
        try folder(["creating": "Making its disk"], modified: Date().addingTimeInterval(-3600))   // kelpd ended midway
        #expect(vms.list().map(\.state) == [.error])
        #expect(throws: RPCError.self) { try vms.connect("deb", cwd: nil) }
    }

    @Test func aFailedOneSaysWhyAndCanBeDeleted() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try folder(["failed": "tar: broken"])
        #expect(vms.list().first.map { ($0.state, $0.detail) }! == (.error, "tar: broken"))
        _ = try vms.control("deb", .delete)
        #expect(vms.list().isEmpty)
    }

    @Test func offOrAsleepFromItsFolderWithoutItsProcess() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try folder([:])
        #expect(vms.list().map(\.state) == [.off])
        try folder(["state.vzsave": "x"])
        #expect(vms.list().map(\.state) == [.sleeping])
    }

    @Test func namesAndImagesAreChecked() {
        #expect(throws: RPCError.self) { try vms.create(VMCreate(name: "Bad Name")) }
        #expect(throws: RPCError.self) { try vms.create(VMCreate(name: "ok", image: "windows")) }
        #expect(throws: RPCError.self) { try vms.machine("nope") }
    }

    /// Agents run commands in machines; making one, shutting it down or deleting it is the user's.
    @Test func whatAgentsMayNotDo() {
        #expect(VMCreate(name: "x").notForAgents != nil)
        #expect(VMControl(name: "x", action: .stop).notForAgents != nil)
        #expect(VMControl(name: "x", action: .delete).notForAgents != nil)
        #expect(VMControl(name: "x", action: .sleep).notForAgents == nil)
        #expect(VMControl(name: "x", action: .start).notForAgents == nil)
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
@Test func aMachinesFileIsCheckedFirst() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kvmf-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let linux = try #require(VMImage.named("linux")), mac = try #require(VMImage.named("macos")), android = try #require(VMImage.named("android"))
    let qcow = dir.appendingPathComponent("a.qcow2"), iso = dir.appendingPathComponent("a.iso"), raw = dir.appendingPathComponent("a.raw")
    try Data([0x51, 0x46, 0x49, 0xFB, 0, 0, 0, 3]).write(to: qcow)
    var isoBytes = Data(count: 0x8006); isoBytes.replaceSubrange(0x8001..<0x8006, with: Data("CD001".utf8)); try isoBytes.write(to: iso)
    try Data(count: 4096).write(to: raw)
    #expect(throws: RPCError.self) { try VMService.check(qcow, for: linux) }
    #expect(throws: RPCError.self) { try VMService.check(iso, for: linux) }
    #expect(throws: RPCError.self) { try VMService.check(raw, for: mac) }   // not an .ipsw
    #expect(throws: RPCError.self) { try VMService.check(raw, for: android) }
    #expect(throws: RPCError.self) { try VMService.check(dir.appendingPathComponent("gone.raw"), for: linux) }
    try VMService.check(raw, for: linux)
}
