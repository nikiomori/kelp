import Foundation
import Core

/// What kelp-vm decides about its machine from where the machine is, apart from Virtualization so it can be tested
/// (KelpVMTests): the runtimes ask these.
enum Lifecycle {
    /// A quit asked `if-down` (a new size is to be written) refused: the machine runs, or a boot is under way (one tried
    /// again has no VM for a second, and is still starting).
    static func refusesQuit(_ args: [String]?, hasVM: Bool, state: VMState) -> Bool {
        args == ["if-down"] && (hasVM || state == .starting)
    }

    /// Whether kelp-vm ends once a sleep is answered: the machine is down (saved, or never up), not starting (a boot tried
    /// again, or one a command asked for meanwhile).
    static func endsAfterSleep(error: String?, hasVM: Bool, state: VMState) -> Bool {
        error == nil && !hasVM && state != .starting
    }

    /// The machine's folder held for this kelp-vm (`kelp-vm.lock`, `VMService.alive`): tried for half a second, as a size
    /// being written or kelpd's look holds it a moment. The fd stays open while kelp-vm runs; nil: another one has it.
    static func hold(_ folder: URL, tries: Int = 10) -> Int32? {
        let fd = open(folder.appendingPathComponent("kelp-vm.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        for n in 0...tries {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            if n < tries { usleep(50_000) }
        }
        close(fd)
        return nil
    }
}
