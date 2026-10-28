import AppKit
import Core
import DesignKit
import KelpKit

/// A blank browser tab offers what the workspace is serving: each port its terminals or agents listen on, to open,
/// copy, or stop. Refreshed every few seconds while it shows.
@MainActor
final class PortsView: NSView {
    var onOpen: ((String) -> Void)?
    private let list = NSStackView()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var shown: [Int]?
    private let app: AppModel

    init(app: AppModel) {
        self.app = app; ports = Watched(.ports, in: app)
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: String(localized: "Running in This Workspace")); title.font = .ui(13, weight: .semibold)
        hint.textColor = .secondaryLabelColor; hint.font = .ui(12)
        hint.stringValue = String(localized: "Servers you start in this workspace's terminals and agents show up here. Or type an address above.")
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        let stack = NSStackView(views: [title, list, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 40), stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
                                     stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
                                     hint.widthAnchor.constraint(lessThanOrEqualToConstant: 460)])
        track(owner: self) { [weak self, app] in self?.ports.key.flatMap { app.ports[$0] } } changed: { [weak self] in self?.show($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); follow() }
    override var isHidden: Bool { didSet { follow() } }

    /// Watched while it shows: the daemon looks every few seconds and says when the ports changed.
    private func follow() {
        let wid = window != nil && !isHidden ? app.workbench.workspaceId : nil
        guard wid != ports.key else { return }
        ports.key = wid; shown = nil
        show(wid.flatMap { app.ports[$0] })
    }
    private let ports: Watched

    private func show(_ found: [PortsList.Port]?) {
        guard let wid = ports.key, let found else { return }
        let numbers = found.map(\.port)
        guard numbers != shown else { return }
        shown = numbers
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for p in found { list.addArrangedSubview(row(p, workspace: wid)) }
        hint.isHidden = !found.isEmpty
    }

    private func row(_ p: PortsList.Port, workspace wid: String) -> NSView {
        let port = p.port, address = "http://localhost:\(port)"
        let link = ClosureButton(title: "localhost:\(port)") { [weak self] in self?.onOpen?(address) }
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.font = .uiDigits(13, weight: .medium)
        let what = NSTextField(labelWithString: p.command)
        what.textColor = .secondaryLabelColor
        what.font = .ui(12)
        let copy = ClosureButton(title: String(localized: "Copy")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
        }
        let stop = ClosureButton(title: String(localized: "Stop")) { [app] in
            Task {
                if await app.call(PortsStop(worktreeId: wid, pid: Int(p.pid))) != nil { app.watchAgain(.ports, wid) }
            }
        }
        for b in [copy, stop] { b.bezelStyle = .push; b.controlSize = .small }
        stop.toolTip = String(localized: "Stops \(p.command.isEmpty ? String(localized: "the process") : p.command) (PID \(Int(p.pid)))")
        let r = NSStackView(views: [link, what, NSView(), copy, stop]); r.spacing = 8
        r.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return r
    }
}
