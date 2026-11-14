import Core
import Foundation

/// A machine kelpd was making when it quit or was upgraded: made again by the next one.
extension VMService {
    /// What `pkill -f` finds a program working in `path` by: the folder as a whole path, as `…/vms/dev` alone is the
    /// start of `…/vms/dev2` too.
    static func inFolder(_ path: String) -> String { NSRegularExpression.escapedPattern(for: path) + "(/| |$)" }

    /// Machines a kelpd before this one was making (it quit or was upgraded midway): made again from the start, their
    /// download going on where it stopped. Called once as kelpd starts.
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

    /// `vm` made again from the start: what a try before left (its kelp-vm, downloads and installer, an iOS one's
    /// simulator, every file but what it is and what it's made from) gone first. A download goes on where it stopped.
    func makeAgain(_ vm: VMMachine) {
        let name = vm.name
        quit(name)
        endLeftovers(name)
        if let udid = text(folder(name).udid) {   // an iOS machine's simulator, made again too
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

    /// The programs still working in its folder (downloads, an installer, an emulator) ended: they outlive the kelpd that
    /// started them, and a machine stopped midway shouldn't go on writing.
    func endLeftovers(_ name: String) {
        do {
            _ = try Subprocess.run(
                ["/usr/bin/pkill", "-TERM", "-f", "--", Self.inFolder(folder(name).path)], cwd: "/", env: [:],
                timeLimit: 10)
        } catch { Log.vm.error("ending what was making \(name): \(error)") }
    }
}
