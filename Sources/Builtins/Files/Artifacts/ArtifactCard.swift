import AppKit
import Core
import DesignKit
import KelpKit
import Markdown

/// The card shown beside the panel when the pointer rests on a page's row. It holds a picture of the top of the page,
/// the page's whole title, and who made it and when. The picture is drawn by `ArtifactShots` from the file, or from
/// Kelp's copy of a page on a service (`ArtifactItem.preview`). Text-heavy pages look alike as thumbnails, but at this
/// size their headings and pictures can be read.
@MainActor
final class ArtifactCard {
    struct Shown {
        let item: ArtifactItem
        let title: String
    }
    static let size = NSSize(width: 284, height: 178)

    private let app: AppModel
    private let card = HoverPopover()
    private var shownTarget: String?
    private let shots = ArtifactShots()
    /// The place for the picture. It is a grey fill until the page is drawn, and then the page fades in.
    private lazy var picture: PictureView = {
        let view = PictureView()
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
        card.onClose = { [weak self] in
            self?.loading?.cancel()
            self?.shownTarget = nil
        }
    }

    /// Called when the pointer moves over a page's row (`shown`), or off every row (nil).
    func hover(_ shown: Shown?, rect: NSRect, in view: NSView) {
        guard let shown else {
            card.closeSoon()
            return
        }
        guard shown.item.target != shownTarget || !card.isShown else {
            card.cancel()
            return
        }
        card.open { [weak self, weak view] in
            if let view { self?.show(shown, rect: rect, in: view) }
        }
    }

    func close() { card.close() }

    private func show(_ shown: Shown, rect: NSRect, in view: NSView) {
        guard view.window != nil else { return }
        shownTarget = shown.item.target
        let controller = NSViewController()
        controller.view = content(shown)
        card.show(controller, relativeTo: rect, of: view, edge: .minX)
    }

    private func content(_ shown: Shown) -> NSView {
        let item = shown.item
        let title = NSTextField(wrappingLabelWithString: shown.title)
        title.font = .ui(TextSize.heading, weight: .semibold)
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
            picture.tint()
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
        // A page published before Kelp kept copies has no picture, so the card starts with its title.
        if item.preview != nil { stack.setCustomSpacing(Metrics.gap + 2, after: picture) }
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
        stack.widthAnchor.constraint(equalToConstant: Self.size.width + 2 * Metrics.inset).isActive = true
        return stack
    }

    private func line(_ text: String) -> NSTextField {
        NSTextField.label(text, font: .ui(TextSize.caption), color: .secondaryLabelColor)
    }

    /// Draws the picture of a page: HTML as it is, Markdown the way its tab draws it. The file is read through the
    /// daemon, as a tab reads it. When the daemon refuses it (too big) or it can't be drawn, the grey fill stays.
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
            picture.crossfade()
            picture.image = image
        }
    }
}

/// The picture's place on the card. Its fill and border are a layer's colours, which keep the appearance they were set
/// in, so they are set again at the moment the Mac goes light or dark with the card up.
private final class PictureView: NSImageView {
    func tint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.fillRest.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint()
    }
}
