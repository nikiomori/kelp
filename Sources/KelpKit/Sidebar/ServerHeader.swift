import AppKit
import Core
import DesignKit

/// How a server's card says its projects run on another machine (Settings › Appearance › Servers): stripes under the
/// whole card, sparser ones in an outline, stripes by the server's icon that fade before the text, or only a striped plate
/// under the icon.
enum ServerLook: String {
    case stripes, sparse, fade, icon
    static let key = "workbench.sidebar.serverLook"
    @MainActor static func of(_ app: AppModel) -> ServerLook {
        app.settings.string(key).flatMap(ServerLook.init) ?? .stripes
    }
}

/// The first row of a server's card, one line as tall as a project's: the machine, a word only when something's wrong,
/// and at the right CPU, memory and disk, each a symbol and its percent (orange from 90), the rest in the tooltip. A click
/// opens the server's tab; under the pointer its icon turns into the chevron that folds its projects away, as a project's.
@MainActor
final class ServerHeader: NSTableCellView {
    let host: String
    private weak var owner: SidebarController?
    private let title = NSTextField(labelWithString: "")
    private let word = NSTextField(labelWithString: "")
    /// At the right: the meters, or why there are none.
    private let meters = NSStackView()
    private let note = NSTextField(labelWithString: "")
    private let cpu = Meter("cpu", String(localized: "CPU")), ram = Meter("memorychip", String(localized: "Memory"))
    private let disk = Meter("internaldrive", String(localized: "Disk"))
    private let glyph = NSImageView(image: .symbol("server.rack"))
    /// The striped plate under the icon, when that is all the card shows of being elsewhere (ServerLook.icon).
    private let plate = NSView()
    private lazy var fold = IconButton(.symbol("chevron.down"), tip: String(localized: "Collapse")) { [weak self] in
        guard let self else { return }
        self.owner?.foldHost(self.host)
    }

    init(host: String, owner: SidebarController) {
        self.host = host
        self.owner = owner
        super.init(frame: .zero)
        glyph.symbolConfiguration = .chrome()
        glyph.contentTintColor = .secondaryLabelColor
        plate.wantsLayer = true
        plate.layer?.cornerRadius = Metrics.radiusSM
        plate.layer?.borderWidth = 1
        title.font = .ui(13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.init(2), for: .horizontal)
        word.font = .uiDigits(11)
        fold.symbolConfiguration = .chrome(Metrics.iconTiny)
        fold.isHidden = true
        note.font = .ui(11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.init(240), for: .horizontal)   // goes before the server's name
        meters.setViews([cpu, ram, disk, note], in: .leading)
        meters.spacing = Metrics.gap
        meters.detachesHiddenViews = true
        let slot = NSView()
        for view in [plate, glyph, fold] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: slot.centerYAnchor)
            ])
        }
        let row = NSStackView(views: [slot, title, word, meters])
        row.spacing = Metrics.gap
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: 16), slot.heightAnchor.constraint(equalToConstant: 16),
            plate.widthAnchor.constraint(equalToConstant: 20), plate.heightAnchor.constraint(equalToConstant: 20),
            fold.widthAnchor.constraint(equalToConstant: 16), fold.heightAnchor.constraint(equalToConstant: 16),
            // The same columns as a project's row (SidebarCell): the icon under theirs, the name under their names.
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.width
        super.setFrameSize(newSize)
        if newSize.width != old { fitMeters() }
    }
    /// All three meters stay while the server's name keeps its first few letters (`nameFloor`); past that they step
    /// aside, the disk first, then memory, then the CPU (all are in the tooltip and on the server's tab).
    private func fitMeters() {
        let name = min(title.intrinsicContentSize.width, Self.nameFloor)
        let said = word.isHidden ? 0 : word.intrinsicContentSize.width + Metrics.gap
        var room = bounds.width - (2 + 16 + Metrics.gap + name + said + Metrics.gap) + meters.spacing
        for meter in [cpu, ram, disk] {
            let need = meter.fittingSize.width + meters.spacing, fits = meter.has && room >= need
            if fits { room -= need }
            meter.isHidden = !fits
        }
    }

    /// About seven letters: enough to tell servers apart.
    static let nameFloor: CGFloat = 52

    override func mouseEntered(with event: NSEvent) { showFold(true) }
    override func mouseExited(with event: NSEvent) { showFold(false) }
    private func showFold(_ on: Bool) {
        fold.isHidden = !on
        glyph.alphaValue = on ? 0 : 1
        plate.alphaValue = on ? 0 : 1
    }

    func update() {
        guard let app = owner?.app else { return }
        let stats = app.latest(HostEvent.self, host)?.stats
        title.stringValue = host
        let said = app.serverWord(host)
        let up = stats?.connected == true
        // Off: the word goes to the right, where the meters would be.
        word.stringValue = up ? said?.text ?? "" : ""
        word.textColor = said?.color ?? .secondaryLabelColor
        word.isHidden = word.stringValue.isEmpty
        note.stringValue = stats == nil ? "" : up ? "" : said?.text ?? ""
        note.textColor = said?.color ?? .secondaryLabelColor
        note.isHidden = note.stringValue.isEmpty
        cpu.show(up ? stats?.cpu.map { Int($0.rounded()) } : nil)
        ram.show(up ? HostStats.percent(stats?.memory, stats?.memoryTotal) : nil)
        disk.show(up ? HostStats.percent(stats?.disk, stats?.diskTotal) : nil)
        fitMeters()
        let look = ServerLook.of(app)
        plate.isHidden = look != .icon
        if look == .icon {   // the appearance is current while the row updates
            plate.layer?.backgroundColor = ProjectCard.stripes(over: .fillRest).cgColor
            plate.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        let folded = owner?.hostFolded(host) == true
        fold.image = .symbol(
            folded ? "chevron.right" : "chevron.down",
            folded ? String(localized: "Expand") : String(localized: "Collapse"))
        fold.toolTip = fold.image?.accessibilityDescription
        toolTip = Self.details(stats)
        setAccessibilityLabel(
            [String(localized: "Server \(host)"), said?.text, toolTip].compactMap { $0 }.joined(separator: ", "))
    }

    /// Everything read, a line each: the tooltip.
    static func details(_ stats: HostStats?) -> String? {
        guard let stats else { return nil }
        guard stats.connected else {
            return stats.error ?? String(localized: "Not connected. Click to open the server, which connects.")
        }
        func of(_ used: Int?, _ total: Int?) -> String? {
            guard let used, let total, let percent = HostStats.percent(used, total) else { return nil }
            return "\(serverBytes(used)) / \(serverBytes(total)) · \(percent)%"
        }
        let load = stats.load.map { $0.map { String(format: "%.2f", $0) }.joined(separator: " ") }
        return [
            serverLine(stats),
            stats.cpu.map { String(localized: "CPU \(Int($0.rounded()))%") + (load.map { " · load " + $0 } ?? "") },
            of(stats.memory, stats.memoryTotal).map { String(localized: "Memory \($0)") },
            of(stats.swap, stats.swapTotal).map { String(localized: "Swap \($0)") },
            of(stats.disk, stats.diskTotal).map { String(localized: "Disk / \($0)") }
        ].compactMap { $0 }.joined(separator: "\n")
    }
}

/// One meter on the header: a symbol and a percent without its sign (there's no room for three), orange from 90.
@MainActor
private final class Meter: NSStackView {
    private let value = NSTextField(labelWithString: "")
    init(_ symbol: String, _ name: String) {
        super.init(frame: .zero)
        let icon = NSImageView(image: .symbol(symbol, name))
        icon.symbolConfiguration = .chrome(Metrics.iconTiny)
        icon.contentTintColor = .secondaryLabelColor
        value.font = .uiDigits(11)
        setViews([icon, value], in: .leading)
        spacing = Metrics.lineGap
    }
    required init?(coder: NSCoder) { fatalError() }

    /// It has a share to show; whether it fits beside the name is the header's to say.
    private(set) var has = false
    func show(_ percent: Int?) {
        has = percent != nil
        guard let percent else { return }
        value.stringValue = "\(percent)"
        value.setAccessibilityLabel("\(percent)%")
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

    /// Each listed server is watched while it's listed (every 10 s, never dialing).
    func watchHosts(_ hosts: Set<String>) {
        for host in hosts.subtracting(watchedHosts) { app.watch(.host, host) }
        for host in watchedHosts.subtracting(hosts) { app.unwatch(.host, host) }
        watchedHosts = hosts
    }

    /// The headers follow every reading; the rows only what they show.
    func updateHeaders() {
        for row in 0..<outline.numberOfRows {
            (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ServerHeader)?.update()
        }
    }

    func serverMenu(_ menu: NSMenu, _ host: String) {
        let app = self.app
        menu.add(String(localized: "Open Server")) { app.openServer(host) }
        menu.addItem(.separator())
        menu.add(String(localized: "New Terminal on \(host)")) { app.runOnServer(host) }
        menu.add(String(localized: "Open htop")) { app.openHtop(host) }
        menu.addItem(.separator())
        menu.add(String(localized: "Add Project on \(host)…")) { app.addProject(onServer: host) }
        if app.latest(HostEvent.self, host)?.stats.connected == true {
            menu.add(String(localized: "Disconnect")) { app.disconnectServer(host) }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Copy Host")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(host, forType: .string)
        }
        menu.addItem(.separator())
        menu.addChoiceMenu(ServerLook.key, app, title: String(localized: "Servers"))
    }

    /// A remote project's: its server's tab and htop there.
    func serverItems(_ menu: NSMenu, _ host: String) {
        let app = self.app
        menu.add(String(localized: "Open Server \(host)")) { app.openServer(host) }
        menu.add(String(localized: "Open htop on \(host)")) { app.openHtop(host) }
        menu.addItem(.separator())
    }
}
