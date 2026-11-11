import AppKit
import Core
import DesignKit
import KelpKit
import Markdown

/// The card a page's row shows when the pointer rests on it, beside the panel: a picture of the page's top (a file's,
/// or Kelp's copy of a page on a service, `ArtifactItem.preview`, drawn by `ArtifactShots`), its whole title, who made
/// it and when. Rows of text-heavy pages look alike in a thumbnail; at this size the page's headings and pictures read.
@MainActor
final class ArtifactCard {
    struct Shown {
        let item: ArtifactItem
        let title: String
    }
    static let size = NSSize(width: 284, height: 178)

    private let app: AppModel
    private let popover = NSPopover()
    private let pending = Debounce()
    private var shownTarget: String?
    private var warmUntil = Date.distantPast
    private var keys: Any?
    private let shots = ArtifactShots()
    /// The picture's place: a grey fill until the page is drawn, then the page, faded in.
    private lazy var picture: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.cornerRadius = Metrics.radiusSM
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true
        return view
    }()
    private var loading: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        popover.behavior = .applicationDefined
        popover.animates = false
    }

    /// The pointer is over a page's row, or over none.
    func hover(_ shown: Shown?, rect: NSRect, in view: NSView) {
        guard let shown else {
            pending.after(Motion.hoverClose) { [weak self] in self?.close() }
            return
        }
        guard shown.item.target != shownTarget || !popover.isShown else {
            pending.cancel()
            return
        }
        let warm = popover.isShown || Date() < warmUntil
        pending.after(warm ? Motion.hoverOpenWarm : Motion.hoverOpen) { [weak self, weak view] in
            if let view { self?.show(shown, rect: rect, in: view) }
        }
    }

    func close() {
        pending.cancel()
        loading?.cancel()
        if popover.isShown {
            warmUntil = Date().addingTimeInterval(0.8)
            popover.close()
        }
        shownTarget = nil
        if let keys {
            NSEvent.removeMonitor(keys)
            self.keys = nil
        }
    }

    private func show(_ shown: Shown, rect: NSRect, in view: NSView) {
        guard view.window != nil else { return }
        shownTarget = shown.item.target
        let controller = NSViewController()
        controller.view = content(shown)
        popover.contentViewController = controller
        popover.show(relativeTo: rect, of: view, preferredEdge: .minX)
        keys =
            keys
            ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.close() }   // local monitors run on the main thread
                return event
            }
    }

    private func content(_ shown: Shown) -> NSView {
        let item = shown.item
        let title = NSTextField(wrappingLabelWithString: shown.title)
        title.font = .ui(TextSize.body, weight: .semibold)
        title.maximumNumberOfLines = 3
        title.preferredMaxLayoutWidth = Self.size.width
        let session = item.session.flatMap(app.session)
        let when = shortAgo(Date(timeIntervalSince1970: item.modified ?? item.created))
        let made = [
            session.map { app.catalog.name($0.agent) },
            session?.status == .exited ? String(localized: "chat ended") : nil,
            String(localized: "\(when) ago")
        ]
        var views: [NSView] = []
        if let preview = item.preview {
            views.append(picture)
            picture.image = nil
            picture.effectiveAppearance.performAsCurrentDrawingAppearance {
                picture.layer?.backgroundColor = NSColor.fillRest.cgColor
                picture.layer?.borderColor = NSColor.separatorColor.cgColor
            }
            let dark = picture.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            load(preview, version: item.modified ?? item.created, dark: dark, board: item.type == "design")
        }
        views += [title, line(made.compactMap { $0 }.joined(separator: " · "))]
        if let link = item.url.flatMap(URL.init(string:))?.host {
            views.append(line(String(localized: "Opens in your browser · \(link)")))
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.lineGap
        // A page published before Kelp kept copies has no picture: the card is its title alone.
        if item.preview != nil { stack.setCustomSpacing(Metrics.gap + 2, after: picture) }
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 10, right: 8)
        stack.widthAnchor.constraint(equalToConstant: Self.size.width + 16).isActive = true
        return stack
    }

    private func line(_ text: String) -> NSTextField {
        NSTextField.label(text, font: .ui(TextSize.caption), color: .secondaryLabelColor)
    }

    /// A page of HTML as it is; Markdown as its tab draws it. Read through the daemon, as a tab reads it; one it
    /// refuses (too big) or that can't be drawn leaves the grey place.
    private func load(_ path: String, version: Double, dark: Bool, board: Bool) {
        loading?.cancel()
        let base = URL(fileURLWithPath: path).deletingLastPathComponent(), app = self.app
        loading = Task { [weak self] in
            guard let text = await app.quiet(FilesRead(path: path))?.text, !Task.isCancelled else { return }
            let html =
                path.hasSuffix(".md")
                ? await Task.detached { MarkdownHTML.page(body: MarkdownHTML.render(text), baseURL: base, dark: dark) }
                    .value : text
            guard !Task.isCancelled, let self,
                let image = await shots.picture(
                    html: html, base: base, key: "\(path)|\(version)", dark: dark,
                    board: board),
                !Task.isCancelled
            else { return }
            let fade = CATransition()
            fade.duration = Motion.fast
            picture.layer?.add(fade, forKey: "fade")
            picture.image = image
        }
    }
}
