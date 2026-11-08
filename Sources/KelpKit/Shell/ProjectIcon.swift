import AppKit
import Core
import DesignKit

/// A project's own icon, found where `IconSearch` looks; its initial when it has none.
@MainActor
package enum ProjectIcon {
    /// The icons found.
    private static var cache: [String: NSImage] = [:]
    /// Each project's initial, and the colour it was drawn in.
    private static var letters: [String: (color: ProjectColor?, image: NSImage)] = [:]
    /// Projects looked at or being looked at.
    private static var searched: Set<String> = []
    /// Projects being looked at, and the views showing their initial meanwhile.
    private static var looking: [String: [Weak]] = [:]
    /// `showing`: what it showed meanwhile; a view that shows something else by then (a reused row) keeps it.
    private struct Weak {
        weak var view: NSImageView?
        let showing: NSImage?
    }

    /// `view` shows the project's icon: its initial at once, the icon when found. `initial` false: what it shows now
    /// (the empty workspace's folder) stays until there's a real icon, the initial being too big a guess at 56 pt.
    package static func show(_ repo: String, in view: NSImageView, app: AppModel, initial: Bool = true) {
        if NoProject.holds(path: repo) {   // chats with no project: Kelp's own folder, not a project's icon
            view.image = .symbol("bubble.left")
            view.shadow = nil
            return
        }
        let image = image(for: repo, app: app), color = app.arrangement.iconColor(folder: repo)
        // The same project's colour changed where it shows (a dot of its menu under the pointer, a pick, the pointer
        // gone): it fades over, and a colour coming flares. A row reused for another project just shows it.
        let recolored =
            initial && showing.object(forKey: view) as String? == repo && view.shadow?.shadowColor != color?.glow
        if recolored { view.crossfade(color == nil ? Motion.fast * 2 / 3 : Motion.fast) }
        if initial || cache[repo] != nil { view.image = image }
        looking[repo]?.append(Weak(view: view, showing: view.image))
        guard initial else { return }
        showing.setObject(repo as NSString, forKey: view)
        halo(on: view, color)
        if recolored, color != nil { flare(view) }
    }
    /// Which project each view showed last.
    private static let showing = NSMapTable<NSImageView, NSString>.weakToStrongObjects()

    /// The Icon style's mark: the project's colour glows around its icon, whatever colours that has itself.
    private static func halo(on view: NSImageView, _ color: ProjectColor?) {
        view.wantsLayer = true
        guard view.shadow?.shadowColor != color?.glow else { return }   // the same glow: a new shadow redraws the blur
        view.shadow = color.map {
            let glow = NSShadow()
            glow.shadowColor = $0.glow
            glow.shadowBlurRadius = Metrics.iconGlow
            return glow
        }
    }

    /// The pointer is over the project's group (Icon style): `glow`, a layer behind its icon, lights up in its colour and
    /// spreads along the row to about twice the icon's width, and goes back when the pointer leaves, from wherever it had
    /// got to. Along the row, not as much up and down: the list clips at its top, and the first project's glow was cut
    /// off there. Its own layer: the icon fades out under the pointer for the row's chevron, and the glow stays.
    static func glow(_ glow: CALayer, color: ProjectColor, _ on: Bool) {
        let side = glow.bounds.width
        let shape = on ? glow.bounds.insetBy(dx: -side * 0.6, dy: -side * 0.2) : glow.bounds.insetBy(dx: 2, dy: 2)
        let corner = shape.height / 2
        let path = CGPath(roundedRect: shape, cornerWidth: corner, cornerHeight: corner, transform: nil)
        let opacity: Float = on ? 1 : 0
        let fromPath = glow.presentation()?.shadowPath ?? glow.shadowPath ?? path
        let fromOpacity = glow.presentation()?.shadowOpacity ?? glow.shadowOpacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.shadowColor = color.glow.cgColor
        glow.shadowOffset = .zero
        glow.shadowRadius = Metrics.iconGlow
        glow.shadowPath = path
        glow.shadowOpacity = opacity
        let moves: [(String, Any, Any)] = [("shadowPath", fromPath, path), ("shadowOpacity", fromOpacity, opacity)]
        for (key, from, to) in moves {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = Motion.duration(on ? Motion.appear : Motion.appear * 2 / 3)
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
            glow.add(animation, forKey: "glow." + key)
        }
        CATransaction.commit()
    }

    /// A glow coming comes wider and settles to its own blur, so the row being coloured is plain to see.
    private static func flare(_ view: NSImageView) {
        guard !Motion.reduced, let layer = view.layer else { return }
        let blur = CAKeyframeAnimation(keyPath: "shadowRadius")   // NSShadow's blur is the layer's radius, one to one
        blur.values = [0, Metrics.iconGlow * 1.8, Metrics.iconGlow]
        blur.keyTimes = [0, 0.4, 1]
        blur.duration = Motion.appear
        blur.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(blur, forKey: "flare")
    }

    /// The project's icon, or its initial while the icon is looked for off the main thread (dozens of folders listed, on
    /// whatever disk the project is on, held up the sidebar); `show` puts the icon in once it's found. A remote project's
    /// is looked for on its host by the daemon, which keeps a copy of it here: it shows again without the host.
    static func image(for repo: String, app: AppModel) -> NSImage {
        if let cached = cache[repo] { return cached }
        if searched.insert(repo).inserted { look(for: repo, app: app) }
        let color = app.arrangement.iconColor(folder: repo)
        if let drawn = letters[repo], drawn.color == color { return drawn.image }
        let letter = IconTile.letter((repo as NSString).lastPathComponent, hue: color?.hue)
        letters[repo] = (color, letter)
        return letter
    }

    private static func look(for repo: String, app: AppModel) {
        looking[repo] = []
        let remote = RemoteHost.of(repo) != nil
        Task {
            let file: String?
            if remote {
                file = await app.quiet(RepoIcon(path: repo)) ?? nil
            } else {
                file = await Task.detached { IconSearch.find(in: repo) }.value
            }
            let found = await Task.detached {
                file.flatMap { p in FileManager.default.contents(atPath: p).map { (p, $0) } }
            }.value
            let views = looking.removeValue(forKey: repo) ?? []
            // The cell's image view scales it to fit; a wordmark (much wider than tall) would be a line, so it's the initial.
            // A Mac app's icon loses its margin and fills a tile, like the agents' icons.
            guard let (file, data) = found, let img = NSImage(data: data), img.size.width <= img.size.height * 2 else {
                return
            }
            let icon = file.hasSuffix(".icns") ? IconTile.app(img) : img
            cache[repo] = icon
            for entry in views where entry.view?.image === entry.showing { entry.view?.image = icon }
        }
    }
}
