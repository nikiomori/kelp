import Core
import Foundation

/// Making an iOS machine (`VMService.create` with the ios image): a simulator of the newest iPhone on the newest iOS the
/// user's Xcode has, named "Kelp <name>", and Kelp's runner (`IOSRunner`) built for it in the machine's folder.
extension VMService {
    func makeIOS(_ machine: VMMachine) async {
        await making(machine) {
            step(machine, .device)
            let json = try await blocking {
                try run(["/usr/bin/xcrun", "simctl", "list", "-j", "runtimes"], limit: 120)
            }
            let (runtime, device) = try Self.newestIPhone(json)
            let made = try await blocking {
                try run(["/usr/bin/xcrun", "simctl", "create", "Kelp \(machine.name)", device, runtime], limit: 120)
            }
            try made.trimmingCharacters(in: .whitespacesAndNewlines).write(
                to: file(machine.name, "udid"), atomically: true, encoding: .utf8)
            step(machine, .building)
            let project = file(machine.name, "runner")
            guard let files = IOSRunner.files else {
                throw RPCError.internalError("This build of Kelp lacks the iOS runner's files.")
            }
            for (path, text) in files {
                let url = project.appendingPathComponent(path)
                try Paths.ensure(url.deletingLastPathComponent())
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            _ = try await blocking {
                try run(
                    [
                        "/usr/bin/xcrun", "xcodebuild", "build-for-testing", "-project",
                        project.appendingPathComponent("KelpRunner.xcodeproj").path,
                        "-scheme", "KelpRunner", "-destination", "generic/platform=iOS Simulator", "-derivedDataPath",
                        file(machine.name, "dd").path,
                        "CODE_SIGNING_ALLOWED=NO", "-quiet"
                    ], limit: 1200)
            }
            step(machine, .starting)
            try await blocking {
                try startHelper(machine)
                try check(ask(machine.name, .init(op: .start), wait: 620))
            }
        }
    }

    /// The newest available iOS runtime and the newest plain iPhone it runs ("iPhone 17" before its Pro and Plus).
    static func newestIPhone(_ json: String) throws -> (runtime: String, device: String) {
        struct List: Decodable {
            struct Runtime: Decodable {
                struct Device: Decodable { var identifier: String, name: String, productFamily: String? }
                var identifier: String, platform: String?, version: String, isAvailable: Bool?,
                    supportedDeviceTypes: [Device]?
            }
            var runtimes: [Runtime]
        }
        let all = try JSONDecoder().decode(List.self, from: Data(json.utf8)).runtimes.filter {
            $0.platform == "iOS" && $0.isAvailable != false
        }
        guard let rt = all.max(by: { $0.version.compare($1.version, options: .numeric) == .orderedAscending }) else {
            throw RPCError.invalidParams(
                "Xcode has no iOS simulator runtime: Xcode › Settings › Components installs one.")
        }
        let phones = (rt.supportedDeviceTypes ?? []).filter { $0.productFamily == "iPhone" }
        // The highest number: the list isn't in age order.
        func number(_ name: String) -> Int { Int(name.split(separator: " ").dropFirst().first ?? "") ?? 0 }
        let plain = phones.filter { $0.name.range(of: #"^iPhone \d+$"#, options: .regularExpression) != nil }.max {
            number($0.name) < number($1.name)
        }
        guard let device = (plain ?? phones.last)?.identifier else {
            throw RPCError.invalidParams("iOS \(rt.version) has no iPhone to simulate.")
        }
        return (rt.identifier, device)
    }
}
