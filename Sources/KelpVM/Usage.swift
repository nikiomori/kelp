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
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var cpu: [pid_t: UInt64] = [:], bytes: UInt64 = 0
        for p in pids.prefix(max(0, n)) where p > 0 && (p == me || responsible(p) == me) {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(p, RUSAGE_INFO_V2, $0) }
            } == 0
            guard ok else { continue }
            cpu[p] = info.ri_user_time + info.ri_system_time
            bytes += info.ri_phys_footprint
        }
        let now = (cpu: cpu, at: mach_absolute_time())
        defer { last = now }
        let percent = last.flatMap { l -> Double? in
            guard now.at > l.at else { return nil }
            let used = cpu.reduce(UInt64(0)) { sum, e in sum + (e.value - min(e.value, l.cpu[e.key] ?? e.value)) }   // a new one: from now
            return Double(used) / Double(now.at - l.at) * 100
        }
        return (percent, Int(bytes >> 20))
    }

    /// The adb clients talking to the emulator `serial` (`adb -s emulator-5600 shell …`), other than kelp-vm's own.
    static func adbClients(_ serial: String) -> Int {
        let me = getpid()
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, n)).filter { p in
            guard p > 0, p != me, Subprocess.parent(p) != me, let argv = Subprocess.arguments(p),
                  argv.first.map({ ($0 as NSString).lastPathComponent }) == "adb" else { return false }
            return zip(argv, argv.dropFirst()).contains { $0 == "-s" && $1 == serial }
        }.count
    }
}
