import AppKit
import Core
import DesignKit

/// A project's own icon, found where `IconSearch` looks; its initial when it has none.
@MainActor
enum ProjectIcon {
    /// The icons found.
    private static var cache: [String: NSImage] = [:]
    /// Each project's initial, and the colour it was drawn in.
    private static var letters: [String: (color: ProjectColor?, image: NSImage)] = [:]
    /// Projects looked at or being looked at.
    private static var searched: Set<String> = []
    /// Projects being looked at, and the views showing their initial meanwhile.
    private static var looking: [String: [Weak]] = [:]
    /// `showing`: what it showed meanwhile; a view that shows something else by then (a reused row) keeps it.
    private struct Weak { weak var view: NSImageView?; let showing: NSImage? }

    /// `view` shows the project's icon: its initial at once, the icon when found. `initial` false: what it shows now
    /// (the empty workspace's folder) stays until there's a real icon, the initial being too big a guess at 56 pt.
    static func show(_ repo: String, in view: NSImageView, app: AppModel, initial: Bool = true) {
        let image = image(for: repo, app: app)
        if initial || cache[repo] != nil { view.image = image }
        looking[repo]?.append(Weak(view: view, showing: view.image))
        if initial { halo(on: view, app.iconColor(folder: repo)) }
    }

    /// The Icon style's mark: the project's colour glows around its icon, whatever colours that has itself.
    private static func halo(on view: NSImageView, _ color: ProjectColor?) {
        view.wantsLayer = true
        view.shadow = color.map {
            let glow = NSShadow()
            glow.shadowColor = $0.glow
            glow.shadowBlurRadius = Metrics.iconGlow
            return glow
        }
    }

    /// The project's icon, or its initial while the icon is looked for off the main thread (dozens of folders listed, on
    /// whatever disk the project is on, held up the sidebar); `show` puts the icon in once it's found. A remote project's
    /// is looked for on its host by the daemon, which keeps a copy of it here: it shows again without the host.
    static func image(for repo: String, app: AppModel) -> NSImage {
        if let i = cache[repo] { return i }
        if searched.insert(repo).inserted { look(for: repo, app: app) }
        let color = app.iconColor(folder: repo)
        if let l = letters[repo], l.color == color { return l.image }
        let letter = IconTile.letter((repo as NSString).lastPathComponent, hue: color?.hue)
        letters[repo] = (color, letter)
        return letter
    }

    private static func look(for repo: String, app: AppModel) {
        looking[repo] = []
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
            for v in views where v.view?.image === v.showing { v.view?.image = icon }
        }
    }
}
