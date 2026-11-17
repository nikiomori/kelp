import Core
import Darwin
import Foundation

/// Measures what a Linux or macOS machine costs the Mac. The guest runs in Virtualization's own processes, not in
/// kelp-vm: one for the machine itself and others for the GPU work of its graphics (about 1 GB for macOS). launchd
/// starts them, and this kelp-vm is the process responsible for them. A sample adds up those processes and kelp-vm.
/// CPU is counted as Activity Monitor counts it (100 % is one core). Memory is the footprint, which is what the guest
/// touched, less what its memory balloon gave back.
@MainActor
enum Usage {
    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    /// A libSystem function missing from its headers. It returns the process that a launchd-started service runs for,
    /// which is how Activity Monitor groups processes.
    private static let responsible = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Responsible.self) }
    /// The CPU time of each process at the last call, and the time of that call, both in mach ticks.
    private static var last: (cpu: [pid_t: UInt64], at: UInt64)?

    /// Returns the CPU percentage since the last call (nil on the first call) and the memory footprint now, in MiB.
    static func sample() -> (cpu: Double?, memoryMiB: Int)? {
        guard let responsible else { return nil }
        let me = getpid()
        var cpu: [pid_t: UInt64] = [:], bytes: UInt64 = 0
        for pid in pids() where pid > 0 && (pid == me || responsible(pid) == me) {
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
            }   // a process that is new since the last call counts from now
            return Double(used) / Double(now.at - previous.at) * 100
        }
        return (percent, Int(bytes >> 20))
    }

    /// Counts the processes of `programs` whose arguments name `id` (`adb -s emulator-5600 shell …`,
    /// `xcrun simctl … <udid>`), leaving out kelp-vm and its children. These are the commands that kelpd and agents run
    /// on the machine without kelp-vm. Processes are matched by name first, so few have their arguments read.
    static func clients(of id: String, programs: Set<String>) -> Int {
        let me = getpid()
        var name = [CChar](repeating: 0, count: 256)
        return pids().filter { pid in
            guard pid > 0, pid != me, proc_name(pid, &name, UInt32(name.count)) > 0,
                programs.contains(String(cBuffer: name)),
                Subprocess.parent(pid) != me, let argv = Subprocess.arguments(pid)
            else { return false }
            return argv.dropFirst().contains { $0.contains(id) }
        }.count
    }

    /// Returns the ids of all processes running now.
    private static func pids() -> ArraySlice<pid_t> {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, count))
    }
}
