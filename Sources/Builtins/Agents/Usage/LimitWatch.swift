import AppKit
import Core
import KelpKit
@preconcurrency import UserNotifications   // its content isn't marked Sendable

/// The plan limits for as long as Kelp runs, from every reading the daemon pushes (`Contributions.pushed`): each limit's
/// pace, and the notifications they call for (a level crossed, full before the reset, unused near it, a reset that lets
/// stopped agents go on), posted through the shell's (`Notifications.notifyUser`).
@MainActor
final class LimitWatch {
    private let app: AppModel
    var forecast = LimitForecast()   // the pace of each limit, from the readings pushed so far
    init(app: AppModel) { self.app = app }

    /// The app's one.
    static func of(_ app: AppModel) -> LimitWatch { app.part { LimitWatch(app: app) } }

    /// The Dock icon's Plan Usage face: the fullest limit read in the last half hour, orange from the warning level.
    static func dockFace(_ app: AppModel) -> DockFace? {
        guard let fullest = app.latest(LimitsEvent.self)?.usage.fresh().map(\.limit.percent).max() else { return nil }
        return dockFace(fullest, warnAt: app.settings.usageAlertAt)
    }
    static func dockFace(_ percent: Double, warnAt: Int?) -> DockFace {
        .usage(percent: Int(percent.rounded()), high: warnAt.map { percent >= Double($0) } ?? false)
    }

    /// Each reading as it lands: the forecast takes every one.
    func landed(_ e: any Pushed) {
        guard let limits = e as? LimitsEvent else { return }
        forecast.record(limits.usage)
        limitsChanged(limits.usage)
    }

    private var limitAlerts = LimitAlerts()
    private var forecastTold = Set<String>()   // limits already warned about, until they stop filling faster than they reset
    private func limitsChanged(_ usage: UsageGet.Result?) {
        guard let usage else { return }
        for a in limitAlerts.update(usage, first: app.settings.usageAlertAt) {
            let name = app.catalog.name(a.agent)
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(name) is at \(Int(a.percent.rounded())) %")
            content.body = a.resets.map { String(localized: "\(a.kind) · resets \($0)") } ?? a.kind
            content.sound = a.level >= 95 ? .default : nil
            Notifications.notifyUser(app, "limit-\(a.agent)-\(a.kind)-\(a.level)", content)
        }
        forecastChanged(usage)
        resetsChanged(usage)
    }

    private var resets = LimitResets()
    private var resetWaits: [String: Task<Void, Never>] = [:]
    private func resetsChanged(_ u: UsageGet.Result) {
        for agent in resets.update(u.fresh()) {
            guard let until = resets.full[agent]?.until else { continue }
            resetWaits[agent]?.cancel()
            resetWaits[agent] = Task { [weak self] in
                // A minute past it: a turn that goes on by itself at the reset has started by then. The clock counts sleep.
                do {
                    try await Task.sleep(until: .now + .seconds(until.timeIntervalSinceNow + 60), clock: .continuous)
                } catch { return }
                self?.limitReset(agent)
            }
        }
    }

    /// A limit that stopped sessions reset: a banner whose Continue tells them to go on.
    private func limitReset(_ agent: String) {
        resetWaits[agent] = nil
        guard let full = resets.end(agent) else { return }
        let app = self.app
        let stopped = LimitResets.stopped(app.sessions, agent: agent, full).filter { !Mutes.isMuted($0, in: app) }
        guard let first = stopped.first else { return }
        let ids = stopped.map(\.id)
        let content = UNMutableNotificationContent()
        let name = app.catalog.name(agent)
        content.title = String(localized: "\(name): the limit has reset")
        content.body = String(
            localized: "Stopped at it: \(stopped.map(app.catalog.displayName).joined(separator: ", "))")
        content.sound = .default
        content.categoryIdentifier = "limitReset"
        content.userInfo = ["session": first.id, "sessions": ids]
        Notifications.notifyUser(
            app, "reset-\(agent)", content, action: (String(localized: "Continue"), { Notifications.goOn(app, ids) }))
    }

    private func forecastChanged(_ u: UsageGet.Result) {
        guard app.settings.usageAlertAt != nil else { return }
        var read = Set<String>()
        for r in u.fresh() {
            let agent = r.agent, l = r.limit, resetAt = r.resetAt
            let key = LimitForecast.key(agent, l.kind), window = UsageGet.window(l.kind)
            read.insert(key)
            // Told again only once its pace eases to 90 % at the reset: a pace that wobbles around full isn't news each read.
            if forecast.atReset(key, resetAt: resetAt, window: window).map({ $0 <= 90 }) ?? true {
                forecastTold.remove(key)
            }
            unusedNearReset(agent, l, resetAt: resetAt, window: window)
            guard let eta = forecast.warning(key, resetAt: resetAt, window: window) else { continue }
            guard forecastTold.insert(key).inserted else { continue }
            let name = app.catalog.name(agent)
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(name): \(l.kind) limit full in \(LimitForecast.duration(eta))")
            content.body = String(localized: "At this pace it fills before it resets.")
            Notifications.notifyUser(app, "forecast-\(key)", content)
        }
        forecastTold.formIntersection(read)
    }

    /// A week (or month) that resets within a day with over half left, once per window: kept across launches, since the
    /// day it holds is long enough to see Kelp quit and open again.
    private func unusedNearReset(_ agent: String, _ l: UsageGet.Limit, resetAt: Date?, window: TimeInterval?) {
        guard LimitForecast.unusedNearReset(percent: l.percent, resetAt: resetAt, window: window), let resetAt else {
            return
        }
        let defaults = UserDefaults.standard, saved = "notifications.unusedTold", key = LimitForecast.key(agent, l.kind)
        var told = defaults.dictionary(forKey: saved) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        guard (told[key].map { now - $0 > 86400 }) ?? true else { return }
        told[key] = now
        defaults.set(told.filter { now - $0.value <= 86400 }, forKey: saved)
        let name = app.catalog.name(agent)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(name): \(Int((100 - l.percent).rounded())) % of the \(l.kind) limit left")
        content.body = String(localized: "Resets \(ResetTime.shown(resetAt)). What isn't used by then is lost.")
        Notifications.notifyUser(app, "unused-\(key)", content)
    }
}

extension SettingsStore {
    /// The share of a plan limit that alerts; nil: never ("off").
    var usageAlertAt: Int? { Int(self[SettingKeys.alertAt]) }
}
