import AppKit
import Core
import DesignKit
import KelpKit

/// What the branch chip opens: one line on where the branch stands against its upstream, the one sync that matters, the
/// commits it would move, and a line to commit what's changed. Everything bigger (staging, history, diffs) stays in Source Control.
@MainActor
final class SyncPopover: NSViewController {
    static let width: CGFloat = 320, shown = 5   // a popover of commits, as the commit card
    /// What reaches past the words' edge: the pad a link line and a text button grey in under the pointer, so their
    /// words keep to the same edge as every other line.
    static let bleed: CGFloat = 4
    static let captionAttributes: [NSAttributedString.Key: Any] =
        [.font: NSFont.ui(11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]

    let app: AppModel
    let wid: String
    weak var popover: NSPopover?

    let name = PointerButton(frame: .zero), state = NSTextField(labelWithString: "")
    lazy var fetch = PointerButton(title: String(localized: "Fetch")) { [weak self] in self?.sync(["fetch"]) }
    lazy var primary = ClosureButton(title: "") { [weak self] in self.map { $0.sync($0.primaryOps) } }
    lazy var commit = ClosureButton(title: String(localized: "Commit")) { [weak self] in self?.commitPressed() }
    let busy = NSProgressIndicator(), note = NSTextField(wrappingLabelWithString: ""), status = NSStackView()
    let outgoing = NSStackView(), incoming = NSStackView(), ci = NSStackView()
    /// The folder whose CI the section shows (a workspace shares its project's): the one the branch chip's mark reads.
    var folder: String { app.gitFolder(of: wid)?.id ?? wid }
    let changes = NSTextField(labelWithString: ""), stats = NSTextField(labelWithString: ""),
        message = NSTextField()
    let nothing = NSTextField(labelWithString: String(localized: "Nothing to commit"))
    let hint = NSTextField(labelWithString: String(localized: "⏎ commit · ⌘⏎ commit and push"))
    let field = NSStackView()
    let root = NSStackView()

    var unsynced: Unsynced?
    var listKey = ""
    var result: (text: String, failed: Bool, rejected: Bool)?
    var primaryOps: [String] = []
    var showIncoming = false, committing = false

    init(app: AppModel, worktree: String) {
        self.app = app
        wid = worktree
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout

    override func loadView() {
        name.padding = 4
        name.imagePosition = .imageTrailing
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        name.target = self
        name.action = #selector(switchMenu)
        name.toolTip = String(localized: "Switch Branch")
        state.font = .ui(12)
        state.textColor = .secondaryLabelColor
        state.lineBreakMode = .byTruncatingMiddle
        state.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        fetch.padding = 4
        fetch.image = .symbol("arrow.down.to.line", String(localized: "Fetch"))   // as Source Control's
        fetch.symbolConfiguration = .chrome()
        fetch.imagePosition = .imageLeading
        fetch.attributedTitle = NSAttributedString(
            string: fetch.title,
            attributes: [.font: NSFont.ui(12), .foregroundColor: NSColor.secondaryLabelColor])
        fetch.contentTintColor = .secondaryLabelColor
        fetch.toolTip = String(localized: "Fetch from the remote")
        let head = NSStackView()
        head.alignment = .top
        head.setViews([name], in: .leading)
        head.setViews([fetch], in: .trailing)

        // The popover's one action, in words alone and the accent (macOS 26's primary tint; the bezel colour before it).
        primary.bezelStyle = .push
        primary.controlSize = .large
        if #available(macOS 26, *) {
            primary.tintProminence = .primary
        } else {
            primary.bezelColor = .controlAccentColor
        }

        busy.style = .spinning
        busy.controlSize = .small
        note.font = .ui(12)
        note.maximumNumberOfLines = 4
        note.preferredMaxLayoutWidth = Self.width - 22
        status.setViews([busy, note], in: .top)
        status.spacing = 6
        status.alignment = .top

        for stack in [outgoing, incoming, ci] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
        }

        let changeHead = NSStackView()
        changeHead.setViews([changes], in: .leading)
        changeHead.setViews([stats], in: .trailing)
        message.placeholderString = String(localized: "Commit message")
        message.delegate = self
        message.target = self
        message.action = #selector(commitPressed)
        field.setViews([message, commit], in: .leading)
        field.spacing = 8
        nothing.font = .ui(12)
        nothing.textColor = .secondaryLabelColor
        hint.font = .ui(11)
        hint.textColor = .secondaryLabelColor   // shown only once there's a message: it says what the keys will do
        // Disabled, the button is its word alone (see showChanges): one box, the field's, not two. Its width stays put.
        commit.widthAnchor.constraint(equalToConstant: commit.fittingSize.width).isActive = true

        // The whole line is the link, its chevron too: it greys in under the pointer and springs when clicked.
        let footer = LinkRow(String(localized: "Open Source Control")) { [weak self] in
            self?.app.workbench.showPanel("git.changes")
            self?.popover?.performClose(nil)
        }

        let rules = (rule(), rule())
        root.orientation = .vertical
        // Every line is centred and as wide as the words, or as wide plus its pad on each side: one left edge.
        root.alignment = .centerX
        root.spacing = 8
        let side = Metrics.inset - Self.bleed
        root.edgeInsets = NSEdgeInsets(top: Metrics.inset, left: side, bottom: Metrics.gapWide, right: side)
        root.setViews(
            [
                head, state, status, primary, ci, outgoing, incoming, rules.0, changeHead, field, nothing, hint,
                rules.1, footer
            ], in: .top)
        let gaps: [(NSView, CGFloat)] = [
            (head, Metrics.lineGap), (state, 12), (primary, 16), (ci, 12), (outgoing, 12), (incoming, 16),
            (rules.0, 12), (field, 12), (hint, 12), (rules.1, 4)
        ]
        for (part, gap) in gaps {
            root.setCustomSpacing(gap, after: part)
        }
        for part in [state, status, primary, outgoing, incoming, changeHead, field, nothing, hint] as [NSView] {
            part.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        }
        for part in [head, footer] as [NSView] {
            part.widthAnchor.constraint(equalToConstant: Self.width + 2 * Self.bleed).isActive = true
        }
        ci.alignment = .centerX   // its caption on the words' edge, its runs' pads past it

        popover?.hasFullSizeContent = true   // the ground reaches under the arrow, else the arrow shows the glass
        view = Self.ground(root)
    }

    /// The popover material under the glass, as Quick Open and the switcher have it: code scrolling behind the popover
    /// shouldn't tint what's written here. It fills the whole popover, arrow included; the words keep clear of the arrow.
    private static func ground(_ content: NSView) -> NSView {
        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .withinWindow
        fx.state = .active
        content.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(content)
        let safe = fx.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: safe.topAnchor),
            content.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: safe.trailingAnchor)
        ])
        return fx
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        track(owner: self) { [app, wid] in
            app.latest(GitEvent.self, wid)
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) { [app, wid] in
            GitSync.state(app).running[wid]
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) { [weak self] in
            self.flatMap { $0.app.latest(CIEvent.self, $0.folder) }
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) { [app] in
            app.settings[SettingKeys.ciPopover]
        } changed: { [weak self] _ in
            self?.update()
        }
    }

    /// Opened for a pull or a push, not to type: the commit field waits for a click.
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil)
    }

    private func rule() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return line
    }

    func label(_ text: String, size: CGFloat = 12, secondary: Bool = true) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .ui(size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

}

/// A line that is a link to somewhere else ("Open Source Control ›"): words on the left, a chevron on the right, the
/// whole line one target that answers the pointer (`PointerControl`).
@MainActor
final class LinkRow: PointerControl {
    private let run: () -> Void
    convenience init(_ title: String, action: @escaping () -> Void) {
        let label = NSTextField(labelWithString: title)
        label.font = .ui(13)
        self.init([label, NSView()], said: title, action: action)
    }
    /// `views` along the row, then the chevron; `said` is what VoiceOver reads for it.
    init(_ views: [NSView], said: String, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        layer?.cornerRadius = Metrics.radiusSM
        let chevron = NSImageView(image: .symbol("chevron.right", ""))
        chevron.contentTintColor = .tertiaryLabelColor
        let row = NSStackView(views: views + [chevron])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        pin(row)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(said)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func clicked() { run() }
    // one target, label included
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
}
