import AppKit
import Core
import DesignKit

/// On a remote project's icon, as Finder badges an alias: a small server at its corner, in the colour of how that machine
/// is (grey fine, orange something wants you, red can't reach, faint not connected). A click opens the server's tab.
@MainActor
final class ServerMark: NSView {
    var host: String?
    var color: NSColor = .secondaryLabelColor { didSet { if color != oldValue { needsDisplay = true } } }
    var opened: ((String) -> Void)?
    static let side: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func draw(_ dirty: NSRect) {
        // A ring of the window's ground cuts it out of the icon under it; the glyph is in that ground too.
        let ground = NSColor.windowBackgroundColor
        ground.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        guard let glyph = NSImage.symbol("server.rack")
            .withSymbolConfiguration(.init(pointSize: 7, weight: .semibold).applying(.init(paletteColors: [ground]))) else { return }
        let s = glyph.size
        glyph.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height))
    }

    override func mouseDown(with e: NSEvent) {}
    override func mouseUp(with e: NSEvent) {
        if let host, bounds.contains(convert(e.locationInWindow, from: nil)) { opened?(host) }
    }
    override func accessibilityPerformPress() -> Bool {
        if let host { opened?(host) }
        return host != nil
    }
}

extension AppModel {
    /// The colour of a server's mark: how the machine is.
    func serverMarkColor(_ host: String) -> NSColor {
        guard let s = hostStats[host] else { return .secondaryLabelColor }
        if !s.connected { return s.error == nil ? .tertiaryLabelColor : .systemRed }
        return s.alert == nil ? .secondaryLabelColor : .systemOrange
    }
}

/// The servers of the projects listed.
extension SidebarController {
    /// Each host a listed project is on is watched while it's listed.
    func watchHosts(_ hosts: Set<String>) {
        for h in hosts.subtracting(watchedHosts) { app.watch(.host, h) }
        for h in watchedHosts.subtracting(hosts) { app.unwatch(.host, h) }
        watchedHosts = hosts
    }

    /// A remote project's: its server's tab, htop there, and letting go of the connection.
    func serverItems(_ menu: NSMenu, _ host: String) {
        let app = self.app
        menu.add(String(localized: "Open Server \(host)")) { app.openServer(host) }
        menu.add(String(localized: "Open htop on \(host)")) { app.openHtop(host) }
        if app.hostStats[host]?.connected == true { menu.add(String(localized: "Disconnect from \(host)")) { app.disconnectServer(host) } }
        menu.addItem(.separator())
    }
}
