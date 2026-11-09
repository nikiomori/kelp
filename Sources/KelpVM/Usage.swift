import Core
import Darwin
import Foundation

/// What a Linux or macOS machine costs the Mac. Its guest runs in Virtualization's own processes, not in kelp-vm: the
/// machine itself and its graphics' GPU tasks (~1 GB for macOS), which launchd starts and this kelp-vm is responsible
/// for. All of them and kelp-vm: CPU as Activity Monitor counts it (100 % = one core), and memory footprints (what the
/// guest touched, less what its balloon gave back).
@MainActor
enum Usage {
    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    /// libSystem's, not in its headers: the process a launchd-started service runs for (as Activity Monitor groups them).
    private static let responsible = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Responsible.self) }
    /// Each process's CPU time at the last call, and when that was (mach ticks both).
    private static var last: (cpu: [pid_t: UInt64], at: UInt64)?

    /// CPU % since the last call (nil on the first), and the footprint now, MiB.
    static func sample() -> (cpu: Double?, memoryMiB: Int)? {
        guard let responsible else { return nil }
        let me = getpid()
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var cpu: [pid_t: UInt64] = [:], bytes: UInt64 = 0
        for pid in pids.prefix(max(0, count)) where pid > 0 && (pid == me || responsible(pid) == me) {
            var info = rusage_info_v2()
            let ok =
                withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                    }
                } == 0
            guard ok else { continue }
            cpu[pid] = info.ri_user_time + info.ri_system_time
            bytes += info.ri_phys_footprint
        }
        let now = (cpu: cpu, at: mach_absolute_time())
        defer { last = now }
        let percent = last.flatMap { previous -> Double? in
            guard now.at > previous.at else { return nil }
            let used = cpu.reduce(UInt64(0)) { sum, e in sum + (e.value - min(e.value, previous.cpu[e.key] ?? e.value))
            }   // a new one: from now
            return Double(used) / Double(now.at - previous.at) * 100
        }
        return (percent, Int(bytes >> 20))
    }

    /// The processes of `programs` that name `id` (`adb -s emulator-5600 shell …`, `xcrun simctl … <udid>`), other than
    /// kelp-vm's own: a machine's commands kelpd and agents run without kelp-vm. By name first: few are read whole.
    static func clients(of id: String, programs: Set<String>) -> Int {
        let me = getpid()
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var name = [CChar](repeating: 0, count: 256)
        return pids.prefix(max(0, count)).filter { pid in
            guard pid > 0, pid != me, proc_name(pid, &name, UInt32(name.count)) > 0,
                programs.contains(
                    String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)),
                Subprocess.parent(pid) != me, let argv = Subprocess.arguments(pid)
            else { return false }
            return argv.dropFirst().contains { $0.contains(id) }
        }.count
    }
}
