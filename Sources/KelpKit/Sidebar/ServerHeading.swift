import AppKit
import Core
import DesignKit

/// A machine's heading over its projects, as Finder heads Locations: the name, quiet, and after it only what wants you
/// ("Disk 92%", "Can't reach"). A click opens the server's tab ("This Mac" folds); the chevron under the pointer folds.
@MainActor
final class ServerHeading: NSTableCellView {
    let host: String
    private weak var owner: SidebarController?
    private let title = NSTextField(labelWithString: "")
    private let word = NSTextField(labelWithString: "")
    private lazy var fold = IconButton(.symbol("chevron.down"), tip: String(localized: "Collapse")) { [weak self] in
        guard let self else { return }
        self.owner?.foldHost(self.host)
    }

    init(host: String, owner: SidebarController) {
        self.host = host
        self.owner = owner
        super.init(frame: .zero)
        title.font = .ui(11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.init(2), for: .horizontal)
        word.font = .uiDigits(11)
        fold.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        fold.isHidden = true
        let row = NSStackView(views: [title, word, fold])
        row.spacing = Metrics.gap
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                                     row.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     row.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     row.heightAnchor.constraint(equalToConstant: Metrics.iconButton)])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) { fold.isHidden = false }
    override func mouseExited(with e: NSEvent) { fold.isHidden = true }

    func update() {
        guard let app = owner?.app else { return }
        title.stringValue = host.isEmpty ? String(localized: "This Mac") : host
        let said = host.isEmpty ? nil : app.serverWord(host)
        word.stringValue = said?.text ?? ""
        word.textColor = said?.color ?? .secondaryLabelColor
        word.isHidden = said == nil
        let folded = owner?.hostFolded(host) == true
        fold.image = .symbol(folded ? "chevron.right" : "chevron.down", folded ? String(localized: "Expand") : String(localized: "Collapse"))
        fold.toolTip = fold.image?.accessibilityDescription
        toolTip = host.isEmpty ? nil : app.hostStats[host]?.error
        setAccessibilityLabel([title.stringValue, said?.text].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The servers' headings in the list.
extension SidebarController {
    func hostFolded(_ host: String) -> Bool { collapsed.contains("h:" + host) }

    func foldHost(_ host: String) {
        if hostFolded(host) { collapsed.remove("h:" + host) } else { collapsed.insert("h:" + host) }
        refresh()
    }

    /// A click on a heading: a server's opens its tab, "This Mac" folds.
    @objc func clicked() {
        guard outline.clickedRow >= 0, case .host(let h)? = (outline.item(atRow: outline.clickedRow) as? Node)?.kind else { return }
        if h.isEmpty { foldHost(h) } else { app.openServer(h) }
    }

    /// Each heading's host is watched while it's listed.
    func watchHosts(_ hosts: Set<String>) {
        for h in hosts.subtracting(watchedHosts) { app.watch(.host, h) }
        for h in watchedHosts.subtracting(hosts) { app.unwatch(.host, h) }
        watchedHosts = hosts
    }

    func serverMenu(_ menu: NSMenu, _ host: String) {
        let app = self.app
        menu.add(String(localized: "Open Server")) { app.openServer(host) }
        menu.addItem(.separator())
        menu.add(String(localized: "New Terminal on \(host)")) { app.runOnServer(host) }
        menu.add(String(localized: "Open htop")) { app.openHtop(host) }
        menu.addItem(.separator())
        menu.add(String(localized: "Add Project on \(host)…")) { app.addProject(onServer: host) }
        if app.hostStats[host]?.connected == true {
            menu.add(String(localized: "Disconnect")) { app.disconnectServer(host) }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Copy Host")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(host, forType: .string)
        }
    }
}
