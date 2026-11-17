import AppKit
import Core
import DesignKit

/// A project's own icon, found where `IconSearch` looks, or the project's initial when it has none.
@MainActor
package enum ProjectIcon {
    /// The icons found.
    private static var cache: [String: NSImage] = [:]
    /// Each project's initial, and the colour it was drawn in.
    private static var letters: [String: (color: ProjectColor?, image: NSImage)] = [:]
    /// Projects whose icon was searched for or is being searched for.
    private static var searched: Set<String> = []
    /// Projects whose icon is being searched for, and the views showing their initial meanwhile.
    private static var looking: [String: [Weak]] = [:]
    /// `showing` is what the view showed meanwhile. A view that shows something else by then (a reused row) keeps what
    /// it shows.
    private struct Weak {
        weak var view: NSImageView?
        let showing: NSImage?
    }

    /// Makes `view` show the project's icon: the initial at once, and the icon when found. With `initial` false, what
    /// the view shows now (the empty workspace's folder) stays until there's a real icon, because at 56 pt the initial
    /// is too big a guess.
    package static func show(_ repo: String, in view: NSImageView, app: AppModel, initial: Bool = true) {
        if NoProject.holds(path: repo) {   // chats with no project live in Kelp's own folder, not a project
            view.image = .symbol("bubble.left")
            view.shadow = nil
            return
        }
        let image = image(for: repo, app: app), color = app.arrangement.iconColor(folder: repo)
        // When the colour of the project the view already shows changes (a dot of its menu under the pointer, a pick,
        // the pointer gone), it fades over, and a new colour flares. A row reused for another project just shows it.
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

    /// The Icon style's mark, a glow of the project's colour around its icon, whatever colours the icon has itself.
    private static func halo(on view: NSImageView, _ color: ProjectColor?) {
        view.wantsLayer = true
        guard view.shadow?.shadowColor != color?.glow else { return }   // same glow; a new shadow would redraw the blur
        view.shadow = color.map {
            let glow = NSShadow()
            glow.shadowColor = $0.glow
            glow.shadowBlurRadius = Metrics.iconGlow
            return glow
        }
    }

    /// Lights `glow`, a layer behind the project's icon, while the pointer is over the project's group (Icon style).
    /// The glow lights up in the project's colour and spreads along the row to about twice the icon's width, and goes
    /// back from wherever it had got to when the pointer leaves. It spreads along the row more than up and down,
    /// because the list clips at its top and the first project's glow was cut off there. It is a layer of its own,
    /// because the icon fades out under the pointer for the row's chevron while the glow stays.
    static func glow(_ glow: CALayer, color: ProjectColor, _ on: Bool) {
        let side = glow.bounds.width
        let shape = on ? glow.bounds.insetBy(dx: -side * 0.6, dy: -side * 0.2) : glow.bounds.insetBy(dx: 2, dy: 2)
        let corner = shape.height / 2
        let path = CGPath(roundedRect: shape, cornerWidth: corner, cornerHeight: corner, transform: nil)
        let duration = on ? Motion.glowIn : Motion.glowOut
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.shadowColor = color.glow.cgColor
        glow.shadowOffset = .zero
        glow.shadowRadius = Metrics.iconGlow
        CATransaction.commit()
        glow.animate("shadowPath", to: path, duration: duration, timing: .easeInEaseOut)
        glow.animate("shadowOpacity", to: Float(on ? 1 : 0), duration: duration, timing: .easeInEaseOut)
    }

    /// Makes a new glow come in wider and settle to its own blur, so the row being coloured is plain to see.
    private static func flare(_ view: NSImageView) {
        guard !Motion.reduced, let layer = view.layer else { return }
        let blur = CAKeyframeAnimation(keyPath: "shadowRadius")   // NSShadow's blur is the layer's radius, one to one
        blur.values = [0, Metrics.iconGlow * 1.8, Metrics.iconGlow]
        blur.keyTimes = [0, 0.4, 1]
        blur.duration = Motion.appear
        blur.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(blur, forKey: "flare")
    }

    /// The project's icon, or its initial while the icon is searched for off the main thread (listing dozens of
    /// folders, on whatever disk the project is on, held up the sidebar). `show` puts the icon in once it is found. The
    /// daemon searches for a remote project's icon on its host and keeps a copy here, so it shows again without the
    /// host.
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
            // The cell's image view scales the image to fit, so a wordmark (much wider than tall) would shrink to a
            // line, and it gets the initial instead. A Mac app's icon loses its margin and fills a tile, like the
            // agents' icons.
            guard let (file, data) = found, let img = NSImage(data: data), img.size.width <= img.size.height * 2 else {
                return
            }
            let icon = file.hasSuffix(".icns") ? IconTile.app(img) : img
            cache[repo] = icon
            for entry in views where entry.view?.image === entry.showing { entry.view?.image = icon }
        }
    }
}
