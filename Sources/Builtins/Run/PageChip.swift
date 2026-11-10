import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// The title bar's way to what the workspace on screen serves, whoever started it: its address opens the page beside you
/// (⇧⌘O; a database's is copied), "+2" opens the Run menu, which lists them all, and a right-click has the rest. There
/// with no run chip too: an agent's server in a project with nothing to run. Hidden while nothing listens.
@MainActor
final class PageChip: ChipCapsule, WindowBarItem {
    private struct Look: Equatable { var workspace: String, page: ServedPage, more: Int }

    /// Only the port, when the bar is short of room.
    var compact = false { didSet { if compact != oldValue { show(look) } } }

    private let app: AppModel
    private let runs: Runs
    private let ports: Watched
    private let open = PointerButton(frame: .zero), more = PointerButton(frame: .zero)

    init(app: AppModel, runs: Runs) {
        self.app = app
        self.runs = runs
        ports = Watched(.ports, in: app)
        super.init()
        hold([open, more], font: .uiDigits(12))
        open.padding = 8
        open.imagePosition = .imageLeading
        open.imageHugsTitle = true
        open.image = .symbol("network", "")
        open.symbolConfiguration = .chrome(Metrics.iconSmall)
        open.onClick = { [weak self] in
            guard let self, let look = look else { return }
            runs.open(look.page, in: look.workspace)
        }
        more.padding = 6
        more.contentTintColor = .secondaryLabelColor
        more.toolTip = String(localized: "Everything Running Here (⌃⌘R)")
        more.onClick = { [weak self] in self?.runs.choose(from: self?.more) }
        isHidden = true
        track(owner: self) { [weak self] in
            self?.look
        } changed: { [weak self] in
            self?.show($0)
        }
        track(owner: self) {
            app.workbench.workspaceId
        } changed: { [weak self] in
            self?.ports.key = $0
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Short of room the page's address comes down to its port. The bar's own width, so the choice can't feed back on
    /// itself.
    func fit(barWidth: CGFloat) { compact = barWidth < 900 }

    private var look: Look? {
        guard let wid = app.workbench.workspaceId else { return nil }
        let pages = runs.pages(wid)
        return pages.first.map { Look(workspace: wid, page: $0, more: pages.count - 1) }
    }

    private func show(_ look: Look?) {
        if isHidden != (look == nil) { crossfade() }
        isHidden = look == nil
        guard let look else { return }
        open.title = compact ? ":\(look.page.port)" : look.page.address
        open.contentTintColor = look.page.offline ? .tertiaryLabelColor : .labelColor
        open.toolTip = tip(look.page)
        open.menu = menu(look)
        more.isHidden = look.more == 0
        more.title = "+\(look.more)"
    }

    private func tip(_ page: ServedPage) -> String {
        if page.offline, let host = page.host {
            return String(localized: "No connection to \(host). The server keeps running there. Click to connect.")
        }
        return page.isWeb
            ? String(localized: "Open \(page.place) (⇧⌘O)") : String(localized: "Copy \(page.place) (⇧⌘O)")
    }

    /// What a click doesn't do. A page that came from a run's printed address may have no process here: a host's.
    private func menu(_ look: Look) -> NSMenu {
        let actions = NSMenu(), app = app, page = PageActions(app)
        if look.page.isWeb {
            actions.add(String(localized: "Open in Browser")) {
                Task {
                    if let url = await page.reach(look.page, in: look.workspace).flatMap({ URL(string: $0.url) }) {
                        PreviewLinks.openOutside(url)
                    }
                }
            }
        }
        actions.add(String(localized: "Copy Address")) { Task { await page.copy(look.page, in: look.workspace) } }
        if look.page.host != nil, look.page.forwarded {
            actions.add(String(localized: "Stop Forwarding")) {
                Task {
                    if await app.call(PortsUnforward(worktreeId: look.workspace, port: look.page.remotePort)) != nil {
                        app.watchAgain(.ports, look.workspace)
                    }
                }
            }
        }
        if let pid = look.page.pid {
            actions.add(String(localized: "Stop")) { Task { await page.stop(pid: pid, in: look.workspace) } }
        }
        return actions
    }
}
