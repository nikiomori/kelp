import Core
import Foundation

/// Picks up the machines kelpd was making when it quit or was upgraded, so the next kelpd makes them again.
extension VMService {
    /// Returns the pattern `pkill -f` uses to find a program working in `path`. It matches the folder as a whole path,
    /// because `…/vms/dev` alone is also the start of `…/vms/dev2`.
    static func inFolder(_ path: String) -> String { NSRegularExpression.escapedPattern(for: path) + "(/| |$)" }

    /// Makes again from the start every machine that an earlier kelpd was making when it quit or was upgraded midway.
    /// Each machine's download goes on where it stopped. kelpd calls this once as it starts.
    func resumeMaking() {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }
        } catch { return }
        for name in names where text(folder(name).creating) != nil && text(folder(name).failed) == nil {
            do {
                let vm = try machine(name)
                Log.vm.info("making \(name) again: a kelpd before this one stopped midway")
                makeAgain(vm)
            } catch { Log.vm.error("making \(name) again: \(error)") }
        }
    }

    /// Returns whether this call is the one that makes `vm` again after making it failed. The check and the claim
    /// happen under one lock (vms/.remaking, held only a moment). The `failed` mark is removed and `creating` is
    /// written before the slow part of `makeAgain`, which takes seconds to quit the machine's kelp-vm or delete a
    /// simulator. So a second Try Again in the meantime (the user clicking twice, or an agent) finds the machine
    /// already being made.
    func claimRemake(_ vm: VMMachine) -> Bool {
        let fd = open(root.appendingPathComponent(".remaking").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }   // closing the file releases the lock too
        flock(fd, LOCK_EX)
        guard failure(vm.name) != nil else { return false }
        remove(folder(vm.name).failed)
        return step(vm, .starting)
    }

    /// Makes `vm` again from the start. First it removes what the earlier try left: the machine's kelp-vm, downloads
    /// and installer, an iOS machine's simulator, and every file except the machine's description (`machine`), the
    /// `creating` mark and what it's made from (`source`). A download goes on where it stopped.
    func makeAgain(_ vm: VMMachine) {
        let name = vm.name
        quit(name)
        endLeftovers(name)
        if let udid = text(folder(name).udid) {   // an iOS machine's simulator is deleted, and made again too
            do {
                try run(["/usr/bin/xcrun", "simctl", "delete", udid.trimmingCharacters(in: .whitespacesAndNewlines)])
            } catch { Log.vm.error("deleting \(name)'s simulator: \(error)") }
        }
        let source = text(folder(name).source).map { URL(fileURLWithPath: $0) }
        let keep = Set([folder(name).machine, folder(name).creating, folder(name).source].map(\.lastPathComponent))
        let made =
            FileManager.default.enumerator(atPath: folder(name).path)?.compactMap { $0 as? String }.filter {
                !$0.contains("/")
            } ?? []
        for entry in made where !keep.contains(entry) { remove(folder(name).file(entry)) }
        step(vm, .starting)
        Task.detached {
            switch vm.kind {
            case .macos: await self.makeMac(vm, ipsw: source)
            case .android: await self.makeAndroid(vm)
            case .ios: await self.makeIOS(vm)
            case .linux: if let image = VMImage.named(vm.image) { await self.make(vm, image, raw: source) }
            }
        }
    }

    /// Ends the programs still working in the machine's folder (downloads, an installer, an emulator). They outlive the
    /// kelpd that started them, and a machine stopped midway shouldn't go on writing.
    func endLeftovers(_ name: String) {
        endChildren(name)
        do {
            _ = try Subprocess.run(
                ["/usr/bin/pkill", "-TERM", "-f", "--", Self.inFolder(folder(name).path)], cwd: "/", env: [:],
                timeLimit: 10)
        } catch { Log.vm.error("ending what was making \(name): \(error)") }
    }

    /// Ends an emulator or runner that a killed kelp-vm left behind, found by the pid kelp-vm noted. A SIGKILL gives
    /// kelp-vm no chance to end them as it leaves. Nothing is ended when that process is already gone.
    func endChildren(_ name: String) {
        for child in ["emulator", "runner"] { folder(name).endChild(child) }
    }
}
