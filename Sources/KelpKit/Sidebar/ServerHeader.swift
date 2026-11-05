import AppKit
import Core
import DesignKit

/// The first row of a server's hatched card: the machine and how it's doing. Its name, and a word only when something's
/// wrong; under it CPU, memory and disk, each a symbol and a share (orange from 90 %), the rest in the tooltip. A click
/// opens the server's tab; the chevron under the pointer folds its projects away.
@MainActor
final class ServerHeader: NSTableCellView {
    let host: String
    private weak var owner: SidebarController?
    private let title = NSTextField(labelWithString: "")
    private let word = NSTextField(labelWithString: "")
    /// Line two: the meters, or why there are none.
    private let meters = NSStackView()
    private let note = NSTextField(labelWithString: "")
    private let cpu = Meter("cpu", String(localized: "CPU")), ram = Meter("memorychip", String(localized: "Memory"))
    private let disk = Meter("internaldrive", String(localized: "Disk"))
    private lazy var fold = IconButton(.symbol("chevron.down"), tip: String(localized: "Collapse")) { [weak self] in
        guard let self else { return }
        self.owner?.foldHost(self.host)
    }

    init(host: String, owner: SidebarController) {
        self.host = host
        self.owner = owner
        super.init(frame: .zero)
        let glyph = NSImageView(image: .symbol("server.rack"))
        glyph.symbolConfiguration = .chrome()
        glyph.contentTintColor = .secondaryLabelColor
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        title.font = .ui(12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.init(2), for: .horizontal)
        word.font = .uiDigits(11)
        fold.symbolConfiguration = .chrome(Metrics.iconTiny)
        fold.isHidden = true
        let top = NSStackView(views: [glyph, title, word, fold])
        top.spacing = Metrics.gap
        top.detachesHiddenViews = true
        note.font = .ui(11)
        note.textColor = .secondaryLabelColor
        meters.setViews([cpu, ram, disk, note], in: .leading)
        meters.spacing = 10
        meters.detachesHiddenViews = true
        for v in [top, meters] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), top.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.topAnchor.constraint(equalTo: topAnchor, constant: 1), top.heightAnchor.constraint(equalToConstant: 18),
            // Under the name, past the server's symbol.
            meters.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meters.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            meters.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 1)
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) { fold.isHidden = false }
    override func mouseExited(with e: NSEvent) { fold.isHidden = true }

    func update() {
        guard let app = owner?.app else { return }
        let s = app.hostStats[host]
        title.stringValue = host
        let said = app.serverWord(host)
        let up = s?.connected == true
        // Off: the word goes to line two, where the meters would be.
        word.stringValue = up ? said?.text ?? "" : ""
        word.textColor = said?.color ?? .secondaryLabelColor
        word.isHidden = word.stringValue.isEmpty
        note.stringValue = s == nil ? "" : up ? "" : said?.text ?? ""
        note.textColor = said?.color ?? .secondaryLabelColor
        note.isHidden = note.stringValue.isEmpty
        cpu.show(up ? s?.cpu.map { Int($0.rounded()) } : nil)
        ram.show(up ? HostStats.percent(s?.memory, s?.memoryTotal) : nil)
        disk.show(up ? HostStats.percent(s?.disk, s?.diskTotal) : nil)
        let folded = owner?.hostFolded(host) == true
        fold.image = .symbol(folded ? "chevron.right" : "chevron.down", folded ? String(localized: "Expand") : String(localized: "Collapse"))
        fold.toolTip = fold.image?.accessibilityDescription
        toolTip = Self.details(s)
        setAccessibilityLabel([String(localized: "Server \(host)"), said?.text, toolTip].compactMap { $0 }.joined(separator: ", "))
    }

    /// Everything read, a line each: the tooltip.
    static func details(_ s: HostStats?) -> String? {
        guard let s else { return nil }
        guard s.connected else { return s.error ?? String(localized: "Not connected. Click to open the server, which connects.") }
        func of(_ used: Int?, _ total: Int?) -> String? {
            guard let used, let total, let p = HostStats.percent(used, total) else { return nil }
            return "\(serverBytes(used)) / \(serverBytes(total)) · \(p)%"
        }
        let load = s.load.map { $0.map { String(format: "%.2f", $0) }.joined(separator: " ") }
        return [serverLine(s),
                s.cpu.map { String(localized: "CPU \(Int($0.rounded()))%") + (load.map { " · load " + $0 } ?? "") },
                of(s.memory, s.memoryTotal).map { String(localized: "Memory \($0)") },
                of(s.swap, s.swapTotal).map { String(localized: "Swap \($0)") },
                of(s.disk, s.diskTotal).map { String(localized: "Disk / \($0)") }].compactMap { $0 }.joined(separator: "\n")
    }
}

/// One meter on the header: a symbol and a share, orange from 90 %.
@MainActor
private final class Meter: NSStackView {
    private let value = NSTextField(labelWithString: "")
    init(_ symbol: String, _ name: String) {
        super.init(frame: .zero)
        let icon = NSImageView(image: .symbol(symbol, name))
        icon.symbolConfiguration = .chrome(Metrics.iconSmall)
        icon.contentTintColor = .secondaryLabelColor
        value.font = .uiDigits(11)
        setViews([icon, value], in: .leading)
        spacing = 3
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ percent: Int?) {
        isHidden = percent == nil
        guard let percent else { return }
        value.stringValue = "\(percent)%"
        value.textColor = percent >= 90 ? .textOrange : .secondaryLabelColor
    }
}

/// The servers' headers in the list.
extension SidebarController {
    func hostFolded(_ host: String) -> Bool { collapsed.contains("h:" + host) }

    func foldHost(_ host: String) {
        if hostFolded(host) { collapsed.remove("h:" + host) } else { collapsed.insert("h:" + host) }
        refresh()
    }

    /// A click on a server's header opens its tab (the header isn't picked, it isn't a place).
    @objc func clicked() {
        guard outline.clickedRow >= 0, case .host(let h)? = (outline.item(atRow: outline.clickedRow) as? Node)?.kind else { return }
        app.openServer(h)
    }

    /// Each listed server is watched while it's listed (every 10 s, never dialing).
    func watchHosts(_ hosts: Set<String>) {
        for h in hosts.subtracting(watchedHosts) { app.watch(.host, h) }
        for h in watchedHosts.subtracting(hosts) { app.unwatch(.host, h) }
        watchedHosts = hosts
    }

    /// The headers follow every reading; the rows only what they show.
    func updateHeaders() {
        for row in 0..<outline.numberOfRows { (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ServerHeader)?.update() }
    }

    func serverMenu(_ menu: NSMenu, _ host: String) {
        let app = self.app
        menu.add(String(localized: "Open Server")) { app.openServer(host) }
        menu.addItem(.separator())
        menu.add(String(localized: "New Terminal on \(host)")) { app.runOnServer(host) }
        menu.add(String(localized: "Open htop")) { app.openHtop(host) }
        menu.addItem(.separator())
        menu.add(String(localized: "Add Project on \(host)…")) { app.addProject(onServer: host) }
        if app.hostStats[host]?.connected == true { menu.add(String(localized: "Disconnect")) { app.disconnectServer(host) } }
        menu.addItem(.separator())
        menu.add(String(localized: "Copy Host")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(host, forType: .string)
        }
    }

    /// A remote project's: its server's tab and htop there.
    func serverItems(_ menu: NSMenu, _ host: String) {
        let app = self.app
        menu.add(String(localized: "Open Server \(host)")) { app.openServer(host) }
        menu.add(String(localized: "Open htop on \(host)")) { app.openHtop(host) }
        menu.addItem(.separator())
    }
}
