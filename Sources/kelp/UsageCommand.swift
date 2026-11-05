import Foundation
import Core

extension Main {
    /// `kelp usage`: each agent's plan limits as Kelp last read them, for an agent to weigh before it hands work on.
    static func usageLimits(_ c: RPCClient) async throws {
        struct Limit: Encodable {
            var agent: String, kind: String, percent: Double, resetsAt: String?, resets: String?, windowSeconds: Int?, readAt: String?, stale: Bool
        }
        let now = Date(), iso = { (d: Date) in d.formatted(.iso8601) }
        let limits = try await c.call(UsageGet()).readings(now: now).sorted { $0.agent < $1.agent }.map { r in
            let read = r.readAt ?? r.limit.observedAt.map { Date(timeIntervalSince1970: $0) }
            return Limit(agent: r.agent, kind: r.limit.kind, percent: r.limit.percent, resetsAt: r.resetAt.map(iso),
                         resets: r.resetAt == nil ? r.limit.resets : nil, windowSeconds: r.window.map { Int($0) }, readAt: read.map(iso),
                         stale: read.map { now.timeIntervalSince($0) > 1800 } ?? false)
        }
        show(["limits": limits])
    }
}
