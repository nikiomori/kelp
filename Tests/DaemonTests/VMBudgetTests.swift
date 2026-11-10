import Core
import Foundation
import Testing
import os

@testable import Daemon

/// The memory budget puts machines to sleep by asking them (`if-idle`): one that's in use by then refuses, and the
/// budget goes on to the next, or says there's no room.
@Suite struct VMBudgetTests {
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
        "kbud-\(UUID().uuidString.prefix(6))")
    var vms: VMService { VMService(home: home, helper: "/nonexistent/kelp-vm") }
    let budget = Int(ProcessInfo.processInfo.physicalMemory >> 20) / 4

    /// A stand-in kelp-vm for `name`: listed running with no connections (idle when the budget looked); a sleep asked
    /// `if-idle` is refused when `busy` (it's in use by now), any other sleep it takes. What it slept is kept.
    private func machine(_ name: String, memoryMiB: Int, busy: Bool, slept: OSAllocatedUnfairLock<[String]>) throws
        -> Int32
    {
        let folder = home.appendingPathComponent("vms/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vm = VMMachine(name: name, image: "debian-13", cpus: 2, memoryMiB: memoryMiB, diskGiB: 8, user: "u")
        try JSONEncoder().encode(vm).write(to: folder.appendingPathComponent("machine.json"))
        let server = try Unix.listen(folder.appendingPathComponent("ctl.sock").path)
        Thread.detachNewThread {
            while case let fd = accept(server, nil, nil), fd >= 0 {
                var b = [UInt8](repeating: 0, count: 4096)
                let n = read(fd, &b, b.count)
                let request = try? JSONDecoder().decode(VMHelper.Request.self, from: Data(b[0..<max(0, n)]))
                var reply = #"{"state":"running","connections":0}"#
                if request?.op == .sleep {
                    if busy && request?.ifIdle == true {
                        reply = #"{"state":"running","connections":1,"error":"in use"}"#
                    } else {
                        slept.withLock { $0.append(name) }
                        reply = #"{"state":"sleeping","connections":0}"#
                    }
                }
                _ = Unix.writeAll(fd, Data(reply.utf8 + [10]))
                close(fd)
            }
        }
        return server
    }

    private func waking(_ memoryMiB: Int) -> VMMachine {
        VMMachine(name: "new", image: "debian-13", cpus: 2, memoryMiB: memoryMiB, diskGiB: 8, user: "u")
    }

    /// The bigger one is in use by the time it's asked: it stays up, and the smaller idle one is slept instead.
    @Test func aMachineInUseByThenIsLeftAndTheNextIsSlept() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let slept = OSAllocatedUnfairLock(initialState: [String]())
        let busy = try machine("busy", memoryMiB: budget / 2 + 10, busy: true, slept: slept)
        let idle = try machine("idle", memoryMiB: budget / 2, busy: false, slept: slept)
        defer {
            close(busy)
            close(idle)
        }
        try vms.admit(waking(1))
        #expect(slept.withLock { $0 } == ["idle"])
    }

    /// Only one up, and it's in use by then: not slept, and there's no room.
    @Test func aMachineInUseByThenLeavesNoRoom() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let slept = OSAllocatedUnfairLock(initialState: [String]())
        let busy = try machine("busy", memoryMiB: budget, busy: true, slept: slept)
        defer { close(busy) }
        #expect(throws: RPCError.self) { try vms.admit(waking(1)) }
        #expect(slept.withLock { $0 }.isEmpty)
    }
}
