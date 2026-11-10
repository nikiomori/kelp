// What can be done with a page a workspace serves, alike wherever it shows.
import AppKit
import Core
import DesignKit
import WorkbenchKit

/// A page a workspace serves, from the run chip, the Run menu, a blank browser tab and a server's tab alike: reached
/// from this Mac, its address copied, what serves it stopped, a host's port forwarded here.
@MainActor
package struct PageActions {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    /// The page as this Mac reaches it (a host's port forwarded here first), the ports read again when that moved it; nil
    /// when it can't be, and a banner says why.
    package func reach(_ page: ServedPage, in wid: String) async -> ServedPage? {
        let here = await page.reached(in: wid) { await app.call($0) }
        if here != page { app.watchAgain(.ports, wid) }
        return here
    }

    /// Its address as this Mac reaches it, on the pasteboard.
    package func copy(_ page: ServedPage, in wid: String) async {
        guard let here = await reach(page, in: wid) else { return }
        copyText(here.address)
        Banner.show(String(localized: "Copied \(here.address)"))
    }

    /// Stops the process listening (`pid`), then reads the ports again.
    package func stop(pid: Int32, in wid: String) async {
        if await app.call(PortsStop(worktreeId: wid, pid: Int(pid))) != nil { app.watchAgain(.ports, wid) }
    }

    /// A host's `port` brought to this Mac: the port it has here; nil when it couldn't be (a banner says why).
    package func forward(_ port: Int, in wid: String) async -> Int? {
        await app.call(PortsForward(worktreeId: wid, port: port))?.port
    }
}
