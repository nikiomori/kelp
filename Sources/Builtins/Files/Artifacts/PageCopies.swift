import AppKit
import Core
import DesignKit
import KelpKit
import SystemConfiguration

/// Whether this Mac reaches claude.ai's network now, as the system tells at once (no request goes out). Without it, a
/// page on claude.ai opens from Kelp's copy (`PageCopies`) instead of the browser.
enum Reach {
    static var offline: Bool {
        guard let target = SCNetworkReachabilityCreateWithName(nil, "claude.ai") else { return false }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(target, &flags) else { return false }
        return !flags.contains(.reachable) || flags.contains(.connectionRequired)
    }
}

/// Kelp's copies of pages on a service: opening one in a page's tab, whole (its pictures and styles beside it), and
/// what the lists say of it.
@MainActor
enum PageCopies {
    /// Whether the page has a copy on this Mac to open.
    static func has(_ item: ArtifactItem) -> Bool { item.url != nil && item.copy != nil }

    /// Opens the copy that works without the network in a page's tab. The daemon writes it first, beside the copy.
    static func open(_ app: AppModel, _ item: ArtifactItem) {
        guard let copy = item.preview else { return }
        let folder = (copy as NSString).deletingLastPathComponent
        Task {
            guard let offline = await app.call(ArtifactOffline(folder: folder)) else { return }
            app.workbench.open(offline)   // an agent's page of HTML, read in its own tab
        }
    }

    /// What the list's Copy column says: whole, missing pictures or styles, none, or on this Mac for a page that lives
    /// here.
    static func state(_ item: ArtifactItem) -> String {
        guard item.url != nil else { return String(localized: "On This Mac") }
        return switch item.copy {
        case .full: String(localized: "Whole")
        case .partial: String(localized: "No Images")
        case nil: String(localized: "None")
        }
    }
}
