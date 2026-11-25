import AppKit
import Core
import DesignKit
import KelpKit

/// Settings › Source Control › Fetch in the background: while Kelp is in front, each project's remotes are fetched
/// every five minutes, and at once when Kelp comes back after longer, so the branch's counts are fresh when they're
/// read. Nothing shows while it runs. A failure is quiet: a word in the popover's line and the chip's tooltip, and
/// after an hour of them a grey mark at the end of the chip. A remote that wants a sign-in isn't asked again until a
/// fetch by hand works. The app has one, as a part (`AppModel.part`).
@MainActor @Observable
final class BackgroundFetch {
    static func of(_ app: AppModel) -> BackgroundFetch { app.part { BackgroundFetch(app: app) } }
    static let every: TimeInterval = 300, markAfter: TimeInterval = 3600

    /// Why a project's last background fetch failed, since when they have, and when the last fetch that worked was.
    struct Trouble: Equatable {
        var kind: QuietFetch.Trouble, host: String?, since: Date, fetched: Double?
    }
    /// By project id. A fetch that works, here or by hand, clears it.
    private(set) var troubles: [String: Trouble] = [:]
    /// How many background fetches have worked, for the popover to read its fetch time again.
    private(set) var fetches = 0
    /// The time the chip's mark is judged by, moved on at each pass, so the mark comes without a click.
    private(set) var now: Date
    /// The clock, which a test moves on.
    @ObservationIgnored var clock: () -> Date = Date.init
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var tried: [String: Date] = [:]
    /// The fetch under way, by project id.
    @ObservationIgnored private(set) var running: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loop: Task<Void, any Error>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(app: AppModel) {
        self.app = app
        now = Date()
        for (name, front) in [
            (NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.inFront(front) }   // queue: .main
                })
        }
        track(owner: self, now: false) {
            app.settings[SettingKeys.fetchInBackground]
        } changed: { [weak self] _ in
            self?.inFront(NSRunningApplication.current.isActive)
        }
        if NSRunningApplication.current.isActive { inFront(true) }
    }
    isolated deinit {
        loop?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Fetches while Kelp is in front: now, for the projects not fetched in the last five minutes, then every five.
    private func inFront(_ front: Bool) {
        loop?.cancel()
        loop = nil
        guard front, app.settings[SettingKeys.fetchInBackground] else { return }
        // Cancelled (Kelp went behind another app, or the setting went off), the sleep throws and ends it.
        loop = Task { [weak self] in
            while true {
                await self?.pass()
                try await Task.sleep(for: .seconds(Self.every))
            }
        }
    }

    /// Fetches each project that is due, one after another. A project is skipped while a pull, push or fetch runs on
    /// any of its folders, and while its remote wants a sign-in.
    func pass() async {
        now = clock()
        guard app.settings[SettingKeys.fetchInBackground] else { return }
        for repo in app.repos {
            guard let folder = app.gitFolder(project: repo.id), troubles[repo.id]?.kind != .signIn,
                tried[repo.id].map({ now.timeIntervalSince($0) >= Self.every - 1 }) ?? true,
                !folders(of: repo.id).contains(where: { GitSync.state(app).running[$0] != nil })
            else { continue }
            tried[repo.id] = now
            let task = Task { [app] in
                guard let outcome = await app.quiet(GitFetchQuietly(worktreeId: folder.id), timeout: 60) else { return }
                self.finished(repo.id, outcome)
            }
            running[repo.id] = task
            await task.value
            running[repo.id] = nil
        }
    }

    private func finished(_ repo: String, _ outcome: QuietFetch) {
        guard outcome.ran else { return }
        if let kind = outcome.trouble {
            troubles[repo] = Trouble(
                kind: kind, host: outcome.host, since: troubles[repo]?.since ?? clock(), fetched: outcome.fetched)
            return
        }
        troubles[repo] = nil
        fetches += 1
        // Worktrees share the project's refs, and only the project's folder sees them move.
        for id in folders(of: repo) { app.watchAgain(.git, app.gitKey(id)) }
    }

    /// Waits for the background fetch of workspace `wid`'s project, if one runs, so a pull or push by hand doesn't
    /// meet it on the refs.
    func settle(_ wid: String) async {
        guard let repo = app.worktree(wid)?.repoId else { return }
        await running[repo]?.value
    }

    /// A fetch or pull by hand that worked clears the project's trouble, a sign-in's too.
    func fetchedByHand(_ wid: String) {
        guard let repo = app.worktree(wid)?.repoId else { return }
        troubles[repo] = nil
        tried[repo] = clock()
    }

    /// Workspace `wid`'s trouble, if its project's background fetch fails. Turned off, nothing of it shows.
    func trouble(_ wid: String) -> Trouble? {
        guard app.settings[SettingKeys.fetchInBackground] else { return nil }
        return app.worktree(wid).flatMap { troubles[$0.repoId] }
    }

    /// The reason in words: "offline", "github.com wants a sign-in". The popover adds what to do about a sign-in.
    static func words(_ trouble: Trouble, inPopover: Bool) -> String {
        switch trouble.kind {
        case .offline: return String(localized: "offline")
        case .other: return String(localized: "couldn’t fetch")
        case .signIn:
            guard inPopover else {
                return trouble.host.map { String(localized: "\($0) wants a sign-in") }
                    ?? String(localized: "the remote wants a sign-in")
            }
            return trouble.host.map { String(localized: "\($0) wants a sign-in, press Fetch") }
                ?? String(localized: "the remote wants a sign-in, press Fetch")
        }
    }

    /// What the branch chip shows of workspace `wid`'s trouble: its tooltip's line ("fetched 1d ago — offline"), and
    /// after an hour of failures a grey mark (no network, or a key for a sign-in).
    func chip(_ wid: String) -> (said: String, mark: String?)? {
        guard let trouble = trouble(wid) else { return nil }
        let said =
            (trouble.fetched.map { SyncPopover.fetched(Date(timeIntervalSince1970: $0)) + " — " } ?? "")
            + Self.words(trouble, inPopover: false)
        let long = now.timeIntervalSince(trouble.since) >= Self.markAfter
        let mark: String? =
            switch trouble.kind {
            case .offline: "wifi.slash"
            case .signIn: "key"
            case .other: nil
            }
        return (said.replacingOccurrences(of: "\u{00A0}", with: " "), long ? mark : nil)
    }

    private func folders(of repo: String) -> [String] { app.worktrees.filter { $0.repoId == repo }.map(\.id) }
}

/// Whether Kelp fetches by itself, read only here and in Settings.
extension SettingKeys {
    static let fetchInBackground = Setting("git.fetchInBackground", true)
}
