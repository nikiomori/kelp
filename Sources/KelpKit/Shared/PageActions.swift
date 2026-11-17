// What can be done with a page a workspace serves, the same wherever the page shows.
import AppKit
import Core
import DesignKit
import WorkbenchKit

/// Actions on a page a workspace serves, shared by the run chip, the Run menu, a blank browser tab and a server's tab.
/// They reach the page from this Mac, copy its address, stop what serves it, and forward a host's port here.
@MainActor
package struct PageActions {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    /// Returns the page as this Mac reaches it (forwarding a host's port here first), and reads the ports again when
    /// that moved the page. Returns nil when the page can't be reached, and a banner says why.
    package func reach(_ page: ServedPage, in wid: String) async -> ServedPage? {
        let here = await page.reached(in: wid) { await app.call($0) }
        if here != page { app.watchAgain(.ports, wid) }
        return here
    }

    /// Copies the page's address, as this Mac reaches it, to the pasteboard.
    package func copy(_ page: ServedPage, in wid: String) async {
        guard let here = await reach(page, in: wid) else { return }
        copyText(here.address)
        Banner.show(String(localized: "Copied \(here.address)"))
    }

    /// Stops the process listening (`pid`), then reads the ports again.
    package func stop(pid: Int32, in wid: String) async {
        if await app.call(PortsStop(worktreeId: wid, pid: Int(pid))) != nil { app.watchAgain(.ports, wid) }
    }

    /// Forwards a host's `port` to this Mac and returns the port it has here. Returns nil when that fails, and a banner
    /// says why.
    package func forward(_ port: Int, in wid: String) async -> Int? {
        await app.call(PortsForward(worktreeId: wid, port: port))?.port
    }
}
