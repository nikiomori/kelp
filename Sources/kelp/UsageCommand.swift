import Core
import Foundation

extension Main {
    /// `kelp usage`: each agent's plan limits as Kelp last read them, for an agent to weigh before it hands work on.
    static func usageLimits(_ c: RPCClient) async throws {
        struct Limit: Encodable {
            var agent: String, kind: String, percent: Double, resetsAt: String?, resets: String?, windowSeconds: Int?,
                readAt: String?, stale: Bool
        }
        let now = Date(), iso = { (date: Date) in date.formatted(.iso8601) }
        let limits = try await c.call(UsageGet()).readings(now: now).sorted { $0.agent < $1.agent }.map { reading in
            let read = reading.readAt ?? reading.limit.observedAt.map { Date(timeIntervalSince1970: $0) }
            return Limit(
                agent: reading.agent, kind: reading.limit.kind, percent: reading.limit.percent,
                resetsAt: reading.resetAt.map(iso),
                resets: reading.resetAt == nil ? reading.limit.resets : nil,
                windowSeconds: reading.window.map { Int($0) },
                readAt: read.map(iso),
                stale: read.map { now.timeIntervalSince($0) > 1800 } ?? false)
        }
        show(["limits": limits])
    }
}
