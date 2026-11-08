import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// A blank browser tab offers what the workspace is serving: each port its terminals or agents listen on, to open,
/// copy, or stop. Refreshed every few seconds while it shows.
@MainActor
final class PortsView: NSView {
    var onOpen: ((String) -> Void)?
    private let list = NSStackView()
    private let empty = EmptyStateView()
    private var shown: [ServedPage]?
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
        ports = Watched(.ports, in: app)
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: String(localized: "Running on This Screen"))
        title.font = .ui(13, weight: .semibold)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        let stack = NSStackView(views: [title, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40)
        ])
        servers = stack
        empty.place(in: self)
        showEmpty(true)
        track(owner: self) { [weak self] in
            self?.pages
        } changed: { [weak self] in
            self?.show($0)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        follow()
    }
    override var isHidden: Bool { didSet { follow() } }

    /// Watched while it shows: the daemon looks every few seconds and says when the ports changed.
    private func follow() {
        let wid = window != nil && !isHidden ? app.workbench.workspaceId : nil
        guard wid != ports.key else { return }
        ports.key = wid
        shown = nil
        show(pages)
    }
    private let ports: Watched
    private var servers: NSView?

    private func showEmpty(_ none: Bool) {
        servers?.isHidden = none
        empty.show(
            none ? String(localized: "Running on This Screen") : nil, symbol: "network",
            text: String(
                localized:
                    "Servers you start in this screen's terminals and agents show up here. Or type an address above."))
    }

    private var pages: [ServedPage]? {
        ports.key.map { ServedPages.list(printed: [], ports: app.latest(PortsEvent.self, $0)?.ports ?? []) }
    }

    private func show(_ found: [ServedPage]?) {
        guard let wid = ports.key, let found, found != shown else { return }
        shown = found
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for page in found { list.addArrangedSubview(row(page, workspace: wid)) }
        showEmpty(found.isEmpty)
    }

    private func row(_ page: ServedPage, workspace wid: String) -> NSView {
        let app = app
        let link = PointerButton(title: page.host == nil ? page.address : page.place) { [weak self] in
            Task {
                guard let here = await page.reached(in: wid, call: { await app.call($0) }) else { return }
                if page.isWeb { self?.onOpen?(here.url) } else { copyText(here.address) }
            }
        }
        link.contentTintColor = .linkColor
        link.font = .uiDigits(13, weight: .medium)
        link.underlinesOnHover = true
        let what = NSTextField(labelWithString: page.command)
        what.textColor = .secondaryLabelColor
        what.font = .ui(12)
        let copy = ClosureButton(title: String(localized: "Copy")) {
            Task { if let here = await page.reached(in: wid, call: { await app.call($0) }) { copyText(here.address) } }
        }
        let stop = ClosureButton(title: String(localized: "Stop")) {
            Task {
                if await app.call(PortsStop(worktreeId: wid, pid: page.pid.map(Int.init))) != nil {
                    app.watchAgain(.ports, wid)
                }
            }
        }
        stop.isHidden = page.pid == nil
        for button in [copy, stop] {
            button.bezelStyle = .push
            button.controlSize = .small
        }
        let command = page.command.isEmpty ? String(localized: "the process") : page.command
        stop.toolTip = String(localized: "Stops \(command) (PID \(Int(page.pid ?? 0)))")
        let row = PortRow(views: [link, what, NSView(), copy, stop])
        row.spacing = 8
        row.items = { menu in
            if page.isWeb { menu.add(String(localized: "Open")) { link.performClick(nil) } }
            menu.add(String(localized: "Copy Address")) { copy.performClick(nil) }
            if page.pid != nil {
                menu.addItem(.separator())
                menu.add(String(localized: "Stop")) { stop.performClick(nil) }
            }
        }
        row.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return row
    }
}

/// A port's row: its buttons again on a right-click.
private final class PortRow: NSStackView {
    var items: ((NSMenu) -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        items?(menu)
        return menu
    }
}
