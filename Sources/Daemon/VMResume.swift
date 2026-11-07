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
        for name in names where text(name, "creating") != nil && text(name, "failed") == nil {
            let m: VMMachine
            do { m = try machine(name) } catch { continue }
            Log.vm.info("making \(name) again: a kelpd before this one stopped midway")
            quit(name)
            // Its downloads and installer outlived that kelpd: ended, not left writing beside the new ones.
            let leftover = Self.inFolder(folder(name).path)
            do {
                _ = try Subprocess.run(
                    ["/usr/bin/pkill", "-TERM", "-f", "--", leftover], cwd: "/", env: [:], timeLimit: 10)
            } catch { Log.vm.error("ending what made \(name) before: \(error)") }
            if let udid = text(name, "udid") {   // an iOS machine's simulator, made again too
                do {
                    try run([
                        "/usr/bin/xcrun", "simctl", "delete", udid.trimmingCharacters(in: .whitespacesAndNewlines)
                    ])
                } catch { Log.vm.error("deleting \(name)'s simulator: \(error)") }
            }
            let source = text(name, "source").map { URL(fileURLWithPath: $0) }
            let keep: Set = ["machine.json", "creating", "source"]
            let made =
                FileManager.default.enumerator(atPath: folder(name).path)?.compactMap { $0 as? String }.filter {
                    !$0.contains("/")
                } ?? []
            for f in made where !keep.contains(f) { remove(file(name, f)) }
            step(m, .starting)
            Task.detached {
                switch m.os {
                case "macos": await self.makeMac(m, ipsw: source)
                case "android": await self.makeAndroid(m)
                case "ios": await self.makeIOS(m)
                default: if let image = VMImage.named(m.image) { await self.make(m, image, raw: source) }
                }
            }
        }
    }
}
