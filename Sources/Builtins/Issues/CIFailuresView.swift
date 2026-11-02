import AppKit
import Core
import DesignKit
import KelpKit

/// What broke in a job: each test or compiler error with its file and message, a click opening the file at that line. A log
/// in no known format says how it ended instead.
@MainActor
final class CIFailuresView: NSView {
    var onOpen: ((CIRuns.Failure) -> Void)?
    var onFix: ((CIRuns.Failure) -> Void)?
    private let list = NSStackView()

    init() {
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = Metrics.gapWide
        list.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.gap, bottom: Metrics.gap, right: Metrics.gap)
        let page = FlippedView()
        page.pin(list)
        let scroll = NSScrollView()
        scroll.documentView = page
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        page.translatesAutoresizingMaskIntoConstraints = false
        pin(scroll)
        NSLayoutConstraint.activate([page.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                                     page.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// False: the log said nothing to show here. `note`: what the run's earlier try says of this.
    @discardableResult func show(_ r: CIRuns.Report, note: String? = nil) -> Bool {
        let rows: [NSView] = r.failures.map { f in
            FailureRow(f, open: { [weak self] in self?.onOpen?(f) }, fix: { [weak self] in self?.onFix?(f) })
        } + (r.more > 0 ? [Self.caption(String(localized: "\(r.more) more in the log"))] : [])
        list.setViews((rows.isEmpty ? Self.ending(r) : Self.count(r) + rows) + (note.map { [Self.caption($0)] } ?? []), in: .top)
        for v in list.arrangedSubviews { v.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -2 * Metrics.gap).isActive = true }
        return !list.arrangedSubviews.isEmpty
    }

    /// "2 of 814 tests failed", when the log counts them.
    private static func count(_ r: CIRuns.Report) -> [NSView] {
        let n = r.failures.filter { $0.test != nil }.count + r.more
        guard n > 0, let tests = r.tests else { return [] }
        return [caption(String(localized: "\(n) of \(tests) tests failed"))]
    }

    /// "Exit 137", then what it printed last.
    private static func ending(_ r: CIRuns.Report) -> [NSView] {
        guard r.exitCode != nil || !r.lastLines.isEmpty else { return [] }
        // Past 128 a shell counts the signal that stopped the process.
        let head = r.exitCode.map { $0 > 128 ? String(localized: "Exit \($0): stopped by signal \($0 - 128)") : String(localized: "Exit \($0)") }
        let lines = r.lastLines.isEmpty ? nil : r.lastLines.joined(separator: "\n")
        return [head.map(caption), lines.map { mono($0, color: .secondaryLabelColor) }].compactMap { $0 }
    }

    fileprivate static func caption(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .ui(11)
        t.textColor = .secondaryLabelColor
        t.lineBreakMode = .byTruncatingMiddle
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return t
    }

    fileprivate static func mono(_ s: String, color: NSColor) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .uiMono(11)
        t.textColor = color
        t.isSelectable = false
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return t
    }
}

/// One failure, one target: the name, where, what it said. Its menu has the rest.
@MainActor
private final class FailureRow: PointerControl {
    private let failure: CIRuns.Failure, open: @MainActor @Sendable () -> Void, fix: @MainActor @Sendable () -> Void

    init(_ f: CIRuns.Failure, open: @escaping @MainActor @Sendable () -> Void, fix: @escaping @MainActor @Sendable () -> Void) {
        failure = f
        self.open = open
        self.fix = fix
        super.init(frame: .zero)
        layer?.cornerRadius = Metrics.radiusSM
        let name = NSTextField(labelWithString: f.test ?? f.place ?? "")
        name.font = .ui(12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let head = NSStackView(views: [CIRunLook.mark("completed", "failure"), name])
        head.spacing = Metrics.gap
        // A panel is narrow: the file's own name and line. The tooltip has its folder, and the class.
        let place = f.test == nil ? nil : f.file.map { file in ((file as NSString).lastPathComponent + (f.line.map { ":\($0)" } ?? "")) } ?? f.suite
        let body = (place.map { [CIFailuresView.caption($0)] } ?? []) + f.messages.map { CIFailuresView.mono($0, color: .textRed) }
        let text = NSStackView(views: body)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.lineGap
        text.edgeInsets = NSEdgeInsets(top: 0, left: 12 + Metrics.gap, bottom: 0, right: 0)
        let all = NSStackView(views: [head, text])
        all.orientation = .vertical
        all.alignment = .leading
        all.spacing = Metrics.lineGap
        all.edgeInsets = NSEdgeInsets(top: 4, left: Metrics.gap, bottom: 4, right: Metrics.gap)
        pin(all)
        isEnabled = f.file != nil
        toolTip = [f.place, f.suite].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(([f.test, f.place] + f.messages.map(Optional.some)).compactMap { $0 }.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func clicked() { open() }
    override func hitTest(_ p: NSPoint) -> NSView? { super.hitTest(p) == nil ? nil : self }   // one target, labels included

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        if failure.file != nil { m.add(String(localized: "Open File"), open) }
        m.add(String(localized: "Fix with Agent"), fix)
        m.addItem(.separator())
        let f = failure
        if let t = f.test { m.add(String(localized: "Copy Test Name")) { Self.copy(t) } }
        m.add(String(localized: "Copy Failure")) { Self.copy(CIRuns.Report.text(of: [f])) }
        return m
    }

    private static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
