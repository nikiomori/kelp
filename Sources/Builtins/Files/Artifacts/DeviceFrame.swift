import AppKit
import DesignKit
import KelpKit
import WebKit

/// Where a page's web view sits: the whole pane (as designed), or a device's screen on the grey under a page (as
/// Safari's Responsive Design Mode shows one), scaled down to fit while the page lays out at the device's own width
/// (`pageZoom`). It follows the web view's hiding.
@MainActor
final class DeviceStage: NSView {
    let web: WKWebView
    /// The device's size in CSS pixels; nil fills the pane.
    var device: NSSize? {
        didSet {
            needsDisplay = true
            web.layer?.cornerRadius = device == nil ? 0 : Metrics.radiusXL
            needsLayout = true
        }
    }
    private var hiding: NSKeyValueObservation?

    init(_ web: WKWebView) {
        self.web = web
        super.init(frame: .zero)
        wantsLayer = true
        web.wantsLayer = true
        web.layer?.masksToBounds = true
        addSubview(web)
        // The split hides the web view by its mode: the stage goes with it.
        hiding = web.observe(\.isHidden, options: [.initial, .new]) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.isHidden = web.isHidden }   // KVO on the main thread, where AppKit set it
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    /// Here, not when the device is set, so the grey follows the window into dark and back.
    override func updateLayer() {
        layer?.backgroundColor = device == nil ? nil : NSColor.underPageBackgroundColor.cgColor
    }

    override func layout() {
        super.layout()
        guard let device else {
            web.frame = bounds
            web.pageZoom = 1
            return
        }
        let room = bounds.insetBy(dx: Metrics.pageInset, dy: Metrics.pageInset)
        let k = max(0.1, min(1, room.width / device.width, room.height / device.height))
        let size = NSSize(width: (device.width * k).rounded(), height: (device.height * k).rounded())
        web.frame = NSRect(
            x: bounds.midX - size.width / 2, y: bounds.maxY - Metrics.pageInset - size.height, width: size.width,
            height: size.height)
        web.pageZoom = k
    }
}

/// In an agent's page bar, for a page or a doc with no width of its own: the device it is seen on (As Designed, a
/// computer, a tablet, a phone, or a size of one's own) and ↻ to turn it. Remembered on this Mac for each page.
@MainActor
final class DeviceControls: NSStackView {
    static let key = "artifacts.device"
    private static let defaults = UserDefaults.standard
    private static let devices: [(name: String, size: NSSize?)] = [
        (String(localized: "As Designed"), nil),
        (String(localized: "Computer"), NSSize(width: 1440, height: 900)),
        (String(localized: "Tablet"), NSSize(width: 820, height: 1180)),
        (String(localized: "Phone"), NSSize(width: 390, height: 844))
    ]
    private let path: String
    private let stage: () -> DeviceStage?
    private let picker = PointerPopUpButton(frame: .zero, pullsDown: true)
    private lazy var turn = IconButton(.symbol("rotate.right"), tip: String(localized: "Turn the Device")) {
        [weak self] in self?.choose(self?.size.map { NSSize(width: $0.height, height: $0.width) })
    }
    private var size: NSSize?

    init(path: String, stage: @escaping () -> DeviceStage?) {
        self.path = path
        self.stage = stage
        super.init(frame: .zero)
        spacing = Metrics.gap
        picker.font = .ui(TextSize.row)
        picker.toolTip = String(localized: "The screen it is seen on")
        addArrangedSubview(picker)
        addArrangedSubview(turn)
        let saved = (Self.defaults.dictionary(forKey: Self.key) as? [String: String])?[path]
        size = saved.map { NSSizeFromString("{" + $0.replacingOccurrences(of: "x", with: ",") + "}") }
        redraw()
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError("not from a nib") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stage()?.device = size
    }

    private func redraw() {
        picker.removeAllItems()
        let named = Self.devices.first { $0.size.map(same) ?? (size == nil) }
        let title = size.map { s in "\(named?.name ?? String(localized: "Custom")) \(Int(s.width))" }
        picker.addItem(withTitle: title ?? String(localized: "As Designed"))
        for device in Self.devices {
            let item = picker.menu?.add(device.name + (device.size.map { " · " + Self.text($0) } ?? "")) {
                [weak self] in self?.choose(device.size)
            }
            item?.state = (device.size.map(same) ?? (size == nil)) ? .on : .off
        }
        picker.menu?.addItem(.separator())
        picker.menu?.add(String(localized: "Custom Size…")) { [weak self] in Task { await self?.askSize() } }
        turn.isHidden = size == nil
    }

    /// Whether `device` is the size shown, either way round.
    private func same(_ device: NSSize) -> Bool {
        size.map { $0 == device || $0 == NSSize(width: device.height, height: device.width) } ?? false
    }

    private static func text(_ s: NSSize) -> String { "\(Int(s.width)) × \(Int(s.height))" }

    private func askSize() async {
        guard
            let answer = await prompt(
                String(localized: "Custom Size"), String(localized: "Width × height, in pixels."),
                initial: size.map(Self.text) ?? "1280 × 800")
        else { return }
        let numbers = answer.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
        guard numbers.count == 2, numbers.allSatisfy({ (100...4000).contains($0) }) else {
            return Banner.show(String(localized: "A size is two numbers from 100 to 4000, such as 1280 × 800."))
        }
        choose(NSSize(width: numbers[0], height: numbers[1]))
    }

    private func choose(_ next: NSSize?) {
        size = next
        var saved = Self.defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        saved[path] = next.map { "\(Int($0.width))x\(Int($0.height))" }
        Self.defaults.set(saved, forKey: Self.key)
        stage()?.device = next
        redraw()
    }
}

extension ArtifactBar {
    /// The device a page or a doc is seen on; a canvas, slides or a motion page has its own size and no such menu.
    func devices() -> NSView {
        let markdown = self.markdown
        let controls = DeviceControls(path: path) { [weak markdown] in markdown?.web.superview as? DeviceStage }
        controls.isHidden = markdown.page != .markdown && markdown.page != .html
        return controls
    }
}
