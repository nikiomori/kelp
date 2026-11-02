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
        self.app = app; ports = Watched(.ports, in: app)
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: String(localized: "Running on This Screen")); title.font = .ui(13, weight: .semibold)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        let stack = NSStackView(views: [title, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 40), stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
                                     stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40)])
        servers = stack
        empty.place(in: self)
        showEmpty(true)
        track(owner: self) { [weak self] in self?.pages } changed: { [weak self] in self?.show($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); follow() }
    override var isHidden: Bool { didSet { follow() } }

    /// Watched while it shows: the daemon looks every few seconds and says when the ports changed.
    private func follow() {
        let wid = window != nil && !isHidden ? app.workbench.workspaceId : nil
        guard wid != ports.key else { return }
        ports.key = wid; shown = nil
        show(pages)
    }
    private let ports: Watched
    private var servers: NSView?

    private func showEmpty(_ none: Bool) {
        servers?.isHidden = none
        empty.show(none ? String(localized: "Running on This Screen") : nil, symbol: "network",
                   text: String(localized: "Servers you start in this screen's terminals and agents show up here. Or type an address above."))
    }

    private var pages: [ServedPage]? { ports.key.map { ServedPages.list(printed: [], ports: app.ports[$0] ?? []) } }

    private func show(_ found: [ServedPage]?) {
        guard let wid = ports.key, let found, found != shown else { return }
        shown = found
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for p in found { list.addArrangedSubview(row(p, workspace: wid)) }
        showEmpty(found.isEmpty)
    }

    private static func copy(_ p: ServedPage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(p.address, forType: .string)
    }

    private func row(_ p: ServedPage, workspace wid: String) -> NSView {
        let app = app
        let link = PointerButton(title: p.host == nil ? p.address : p.place) { [weak self] in
            Task {
                guard let here = await p.reached(in: wid, call: { await app.call($0) }) else { return }
                if p.isWeb { self?.onOpen?(here.url) } else { Self.copy(here) }
            }
        }
        link.contentTintColor = .linkColor
        link.font = .uiDigits(13, weight: .medium)
        link.underlinesOnHover = true
        let what = NSTextField(labelWithString: p.command)
        what.textColor = .secondaryLabelColor
        what.font = .ui(12)
        let copy = ClosureButton(title: String(localized: "Copy")) {
            Task { if let here = await p.reached(in: wid, call: { await app.call($0) }) { Self.copy(here) } }
        }
        let stop = ClosureButton(title: String(localized: "Stop")) {
            Task {
                if await app.call(PortsStop(worktreeId: wid, pid: p.pid.map(Int.init))) != nil { app.watchAgain(.ports, wid) }
            }
        }
        stop.isHidden = p.pid == nil
        for b in [copy, stop] { b.bezelStyle = .push; b.controlSize = .small }
        stop.toolTip = String(localized: "Stops \(p.command.isEmpty ? String(localized: "the process") : p.command) (PID \(Int(p.pid ?? 0)))")
        let r = NSStackView(views: [link, what, NSView(), copy, stop]); r.spacing = 8
        r.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return r
    }
}
