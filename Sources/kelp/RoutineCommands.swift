import Foundation
import Core

extension Main {
    /// `routine add|list|run|rm`.
    static func routines(_ sub: String?, _ c: RPCClient) async throws {
        func id() async throws -> String {
            let p = args.first ?? "", found = try await c.call(RoutineList()).routines.map(\.id).filter { !p.isEmpty && $0.hasPrefix(p) }
            guard found.count == 1 else { fail(found.isEmpty ? "no routine \(p) (see `kelp routine list`)" : "ambiguous: \(p)") }
            return found[0]
        }
        switch sub {
        case "add":
            let prompt = flag("--prompt"), agent = flag("--agent") ?? "claude", model = flag("--model")
            let every = Routine.Every(rawValue: flag("--every") ?? "weekdays") ?? .weekdays
            let at = flag("--at") ?? (every == .hourly ? ":00" : "9:00"), day = flag("--day") ?? "mon", skip = has("--skip-missed")
            let hm = at.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
            let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            guard let prompt, let name = args.first, let weekday = days.firstIndex(of: String(day.lowercased().prefix(3))) else {
                fail("routine add <name> --prompt <text> [--every hourly|daily|weekdays|weekly] [--at 9:00] [--day mon]")
            }
            let time = hm.count > 1 ? hm[0] * 60 + hm[1] : hm[0] * 60
            show(try await c.call(RoutineSet(routine: Routine(name: name, repoId: try await currentRepoID(c), agent: agent, model: model, prompt: prompt,
                                                              every: every, time: time, weekday: weekday + 1, onWake: !skip))))
        case "list": show(try await c.call(RoutineList()))
        case "run": show(try await c.call(RoutineRun(id: try await id())))
        case "rm": _ = try await c.call(RoutineDelete(id: try await id()))
        default: print(usage)
        }
    }
}
