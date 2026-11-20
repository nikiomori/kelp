import AppKit
import Core
import DesignKit
import KelpKit
import WebKit
import WorkbenchKit

/// The ⋯ menu on a browser tab's bar. It opens the page in the Mac's own browser, sets the page's size, takes a
/// screenshot or a recording, and clears the site's cookies.
@MainActor
extension BrowserTab {
    @objc func openExternal() { if let url = web.url { PreviewLinks.openOutside(url) } }

    static func openIn(_ browser: (name: String, icon: NSImage)?) -> String {
        browser.map { String(localized: "Open in \($0.name)") } ?? String(localized: "Open in Browser")
    }

    /// Returns the name and icon of the browser that opens web links on this Mac, so the button says where the page
    /// goes.
    static func defaultBrowser() -> (name: String, icon: NSImage)? {
        guard let probe = URL(string: "https://example.com"),
            let app = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: Metrics.appIcon, height: Metrics.appIcon)
        return ((FileManager.default.displayName(atPath: app.path) as NSString).deletingPathExtension, icon)
    }

    @objc func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        menu.add(Self.openIn(Self.defaultBrowser())) { [weak self] in self?.openExternal() }
        menu.addItem(pageSizes())
        menu.addItem(.separator())
        menu.add(String(localized: "Reload Ignoring Cache")) { [weak self] in self?.reloadPage(fromOrigin: true) }
        menu.add(String(localized: "Copy Screenshot")) { [weak self] in self?.copyScreenshot() }
        if recording == nil {
            menu.add(String(localized: "Record Video")) { [weak self] in self?.recordFromMenu(gif: false) }
            menu.add(String(localized: "Record GIF")) { [weak self] in self?.recordFromMenu(gif: true) }
        } else {
            menu.add(String(localized: "Stop Recording")) { [weak self] in self?.saveRecording() }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Clear Cookies and Data for This Site…")) { [weak self] in self?.clearSiteData() }
        menu.addItem(.separator())
        let tip = menu.addItem(
            withTitle: String(localized: "Inspect: right-click the page › Inspect Element"), action: nil,
            keyEquivalent: "")
        tip.isEnabled = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    func copyScreenshot() {
        web.takeSnapshot(with: nil) { img, _ in   // WebKit calls back on the main thread
            MainActor.assumeIsolated {
                guard let img else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([img])
                Banner.show(String(localized: "Screenshot copied"))
            }
        }
    }

    /// ⋯ › Page Size: shows the page at the size of a phone, a tablet or a laptop, to check its layout there, or
    /// filling the pane.
    func pageSizes() -> NSMenuItem {
        let sizes: [(String, CGSize?)] = [
            (String(localized: "Fill the Pane"), nil),
            (String(localized: "Phone 390×844"), CGSize(width: 390, height: 844)),
            (String(localized: "Tablet 820×1180"), CGSize(width: 820, height: 1180)),
            (String(localized: "Laptop 1280×800"), CGSize(width: 1280, height: 800))
        ]
        let menu = NSMenu()
        for (name, size) in sizes {
            menu.add(name) { [weak self] in
                self?.viewport = size
                self?.placeWeb()
            }
            .state = viewport == size ? .on : .off
        }
        if let viewport, !sizes.contains(where: { $0.1 == viewport }) {
            menu.add(String(localized: "\(Int(viewport.width))×\(Int(viewport.height)) (the agent’s)")) {}.state = .on
        }
        let item = NSMenuItem(title: String(localized: "Page Size"), action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// Asks first, because it signs the person out of the site.
    func clearSiteData() {
        guard let host = web.url?.host else {
            NSSound.beep()
            return
        }
        Task { [weak self] in
            guard
                await confirm(
                    String(localized: "Clear \(host)’s cookies and data?"),
                    detail: String(localized: "You’re signed out of it, and the page loads again."),
                    action: String(localized: "Clear"), destructive: true)
            else { return }
            self?.removeSiteData(host)
        }
    }

    private func removeSiteData(_ host: String) {
        let store = web.configuration.websiteDataStore, types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { [weak self] records in
            guard self != nil else { return }
            let mine = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
            store.removeData(ofTypes: types, for: mine) { [weak self] in   // WebKit calls back on the main thread
                MainActor.assumeIsolated {
                    Banner.show(String(localized: "Cleared \(host)’s cookies and data"))
                    self?.web.reload()
                }
            }
        }
    }
}
