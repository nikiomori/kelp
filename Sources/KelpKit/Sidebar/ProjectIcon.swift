import AppKit
import Core

/// A project's own icon, found where `IconSearch` looks; its initial when it has none.
@MainActor
enum ProjectIcon {
    private static var cache: [String: NSImage] = [:]
    /// Projects being looked at, and the views showing their initial meanwhile.
    private static var looking: [String: [Weak]] = [:]
    /// `showing`: what it showed meanwhile; a view that shows something else by then (a reused row) keeps it.
    private struct Weak { weak var view: NSImageView?; let showing: NSImage? }
    private static var found: Set<String> = []

    /// `view` shows the project's icon: its initial at once, the icon when found. `initial` false: what it shows now
    /// (the empty workspace's folder) stays until there's a real icon, the initial being too big a guess at 56 pt.
    static func show(_ repo: String, in view: NSImageView, app: AppModel, initial: Bool = true) {
        let image = image(for: repo, app: app)
        if initial || found.contains(repo) { view.image = image }
        looking[repo]?.append(Weak(view: view, showing: view.image))
    }

    /// The project's icon, or its initial while the icon is looked for off the main thread (dozens of folders listed, on
    /// whatever disk the project is on, held up the sidebar); `show` puts the icon in once it's found. A remote project's
    /// is looked for on its host by the daemon, which keeps a copy of it here: it shows again without the host.
    static func image(for repo: String, app: AppModel) -> NSImage {
        if let i = cache[repo] { return i }
        let letter = IconTile.letter((repo as NSString).lastPathComponent)
        cache[repo] = letter; looking[repo] = []
        let remote = RemoteHost.of(repo) != nil
        Task {
            let file: String?
            if remote { file = await app.quiet(RepoIcon(path: repo)) ?? nil } else { file = await Task.detached { IconSearch.find(in: repo) }.value }
            let found = await Task.detached { file.flatMap { p in FileManager.default.contents(atPath: p).map { (p, $0) } } }.value
            let views = looking.removeValue(forKey: repo) ?? []
            // The cell's image view scales it to fit; a wordmark (much wider than tall) would be a line, so it's the initial.
            // A Mac app's icon loses its margin and fills a tile, like the agents' icons.
            guard let (file, data) = found, let img = NSImage(data: data), img.size.width <= img.size.height * 2 else { return }
            let icon = file.hasSuffix(".icns") ? IconTile.app(img) : img
            cache[repo] = icon
            Self.found.insert(repo)
            for v in views where v.view?.image === v.showing { v.view?.image = icon }
        }
        return letter
    }
}
