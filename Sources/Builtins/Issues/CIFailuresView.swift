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
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            page.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// False: the log said nothing to show here. `note`: what the run's earlier try says of this.
    @discardableResult func show(_ report: CIRuns.Report, note: String? = nil) -> Bool {
        let rows: [NSView] =
            report.failures.map { failure in
                FailureRow(
                    failure, open: { [weak self] in self?.onOpen?(failure) },
                    fix: { [weak self] in self?.onFix?(failure) })
            } + (report.more > 0 ? [Self.caption(String(localized: "\(report.more) more in the log"))] : [])
        list.setViews(
            (rows.isEmpty ? Self.ending(report) : Self.count(report) + rows) + (note.map { [Self.caption($0)] } ?? []),
            in: .top)
        for row in list.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -2 * Metrics.gap).isActive = true
        }
        return !list.arrangedSubviews.isEmpty
    }

    /// "2 of 814 tests failed", when the log counts them.
    private static func count(_ report: CIRuns.Report) -> [NSView] {
        let failed = report.failures.filter { $0.test != nil }.count + report.more
        guard failed > 0, let tests = report.tests else { return [] }
        return [caption(String(localized: "\(failed) of \(tests) tests failed"))]
    }

    /// "Exit 137", then what it printed last.
    private static func ending(_ report: CIRuns.Report) -> [NSView] {
        guard report.exitCode != nil || !report.lastLines.isEmpty else { return [] }
        // Past 128 a shell counts the signal that stopped the process.
        let head = report.exitCode.map {
            $0 > 128 ? String(localized: "Exit \($0): stopped by signal \($0 - 128)") : String(localized: "Exit \($0)")
        }
        let lines = report.lastLines.isEmpty ? nil : report.lastLines.joined(separator: "\n")
        return [head.map(caption), lines.map { mono($0, color: .secondaryLabelColor) }].compactMap { $0 }
    }

    fileprivate static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .ui(TextSize.caption)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    fileprivate static func mono(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .uiMono(TextSize.caption)
        label.textColor = color
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

/// One failure, one target: the name, where, what it said. Its menu has the rest.
@MainActor
private final class FailureRow: PointerControl {
    private let failure: CIRuns.Failure, open: @MainActor @Sendable () -> Void, fix: @MainActor @Sendable () -> Void

    init(
        _ failure: CIRuns.Failure, open: @escaping @MainActor @Sendable () -> Void,
        fix: @escaping @MainActor @Sendable () -> Void
    ) {
        self.failure = failure
        self.open = open
        self.fix = fix
        super.init(frame: .zero)
        layer?.cornerRadius = Metrics.radiusSM
        let name = NSTextField(labelWithString: failure.test ?? failure.place ?? "")
        name.font = .ui(TextSize.row, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let head = NSStackView(views: [CIRunLook.mark("completed", "failure"), name])
        head.spacing = Metrics.gap
        // A panel is narrow: the file's own name and line. The tooltip has its folder, and the class.
        let place =
            failure.test == nil
            ? nil
            : failure.file.map { file in ((file as NSString).lastPathComponent + (failure.line.map { ":\($0)" } ?? ""))
            } ?? failure.suite
        let body =
            (place.map { [CIFailuresView.caption($0)] } ?? [])
            + failure.messages.map { CIFailuresView.mono($0, color: .textRed) }
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
        isEnabled = failure.file != nil
        toolTip = [failure.place, failure.suite].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            ([failure.test, failure.place] + failure.messages.map(Optional.some)).compactMap { $0 }.joined(
                separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func clicked() { open() }
    // one target, labels included
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func menu(for event: NSEvent) -> NSMenu? {
        let failure = failure
        let menu = NSMenu()
        if failure.file != nil { menu.add(String(localized: "Open File"), open) }
        menu.add(String(localized: "Fix with Agent"), fix)
        menu.addItem(.separator())
        if let test = failure.test { menu.add(String(localized: "Copy Test Name")) { copyText(test) } }
        menu.add(String(localized: "Copy Failure")) { copyText(CIRuns.Report.text(of: [failure])) }
        return menu
    }
}
