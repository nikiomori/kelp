import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// What a blank browser tab shows: the ports the workspace's terminals and agents listen on, each to open, copy or
/// stop. It is a `SectionList`, as the server page's ports are: rows that light up under the pointer, ↑ ↓ and Return,
/// and a right-click menu. The list is refreshed every few seconds while it shows.
@MainActor
final class PortsView: NSView {
    var onOpen: ((String) -> Void)?
    private let list = NSHostingView(rootView: SectionList([]))
    private let empty = EmptyStateView()
    private var shown: [ServedPage]?
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
        ports = Watched(.ports, in: app)
        super.init(frame: .zero)
        list.sizingOptions = []
        list.translatesAutoresizingMaskIntoConstraints = false
        addSubview(list)
        // A page's column: its top, and its sides a panel's inset short of the page's, where the rows' words start.
        let side = Metrics.pageInset - Metrics.inset
        let fill = list.widthAnchor.constraint(equalToConstant: Metrics.pageColumn)
        fill.priority = .defaultHigh   // in a narrower pane the list is the pane's width
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.pageTop),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),
            list.centerXAnchor.constraint(equalTo: centerXAnchor),
            list.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * side), fill
        ])
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

    /// Watches the workspace's ports while the view shows. The daemon looks every few seconds and says when the ports
    /// changed.
    private func follow() {
        let wid = window != nil && !isHidden ? app.workbench.workspaceId : nil
        guard wid != ports.key else { return }
        ports.key = wid
        shown = nil
        show(pages)
    }
    private let ports: Watched

    private func showEmpty(_ none: Bool) {
        list.isHidden = none
        empty.show(
            none ? String(localized: "Nothing running on this screen") : nil, symbol: "network",
            text: String(
                localized:
                    "Servers you start in this screen’s terminals and agents show up here. Or type an address above."))
    }

    private var pages: [ServedPage]? {
        ports.key.map { ServedPages.list(printed: [], ports: app.latest(PortsEvent.self, $0)?.ports ?? []) }
    }

    private func show(_ found: [ServedPage]?) {
        guard let wid = ports.key, let found, found != shown else { return }
        shown = found
        let rows = found.map { row($0, workspace: wid) }
        list.rootView = SectionList([
            .init(id: "ports", title: String(localized: "Running on This Screen"), rows: rows)
        ])
        showEmpty(found.isEmpty)
    }

    /// A port's row: its number, what listens, and where a remote one really is. A web page's address opens it in this
    /// tab; anything else (a database, a debugger) copies its address, offered under the pointer.
    private func row(_ page: ServedPage, workspace wid: String) -> SectionList.Row {
        let actions = PageActions(app)
        let command = page.command.isEmpty ? String(localized: "the process") : page.command
        var row = SectionList.Row(id: "port \(page.host ?? ""):\(page.remotePort)", title: command)
        row.key = "\(page.port)"
        row.trailing = page.host == nil ? nil : page.place
        let copy = SectionList.Action(String(localized: "Copy Address")) { Task { await actions.copy(page, in: wid) } }
        if page.isWeb {
            let open = SectionList.Action(String(localized: "Open")) { [weak self] in
                Task { if let here = await actions.reach(page, in: wid) { self?.onOpen?(here.url) } }
            }
            row.link = .init(page.address, tip: String(localized: "Open in This Tab"), run: open.run)
            row.open = open.run
            row.menu = [open, copy]
        } else {
            row.button = .init(String(localized: "Copy"), run: copy.run)
            row.onHover = true
            row.open = copy.run
            row.menu = [copy]
        }
        if let pid = page.pid {
            row.menu.append(
                .init(String(localized: "Stop"), tip: String(localized: "Stops \(command) (PID \(Int(pid)))")) {
                    Task { await actions.stop(pid: pid, in: wid) }
                })
        }
        return row
    }
}
