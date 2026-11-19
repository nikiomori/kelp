import AppKit
import SwiftUI

/// What a panel, a tab or a window shows while what it lists is on its way: a small spinner and one secondary line
/// beside it (with a `detail` under them). It stands where `EmptyStateView` stands, lifted as it is, so one gives way
/// to the other without a jump. A list's loading view (`rows`) shows the shape of the rows to come instead, with a
/// light passing over them. It fades in and out, so the list it gives way to seems to come out of it.
@MainActor
public final class LoadingView: NSView {
    private let spinner = NSProgressIndicator()
    private let line = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let skeleton: SkeletonRows?
    /// What a wait shows stays up at least this long, so an answer right behind it doesn't make it blink.
    public static let held: TimeInterval = 0.4
    private var shownAt: Date?
    /// Counts the leaves while the view fades away. A show meanwhile keeps it, and only the last leave hides it.
    private var leaving: Int?
    private var leaves = 0
    /// The wait that `wait` started, which shows the view once it is slow.
    private var waiting: Task<Void, Never>?
    /// The longest a wait started by `wait` stays up.
    public static let longest: TimeInterval = 30
    /// How long `wait` says nothing: a second, by the latency rule. A test shortens it, so that its wait is due before
    /// a busy run's other tests take the main thread.
    nonisolated(unsafe) public static var patience: TimeInterval = 1
    /// True while the view is on screen and not on its way out.
    public var showing: Bool { !isHidden && leaving == nil }

    public init(rows: Bool = false) {
        skeleton = rows ? SkeletonRows() : nil
        super.init(frame: .zero)
        if let skeleton {
            pin(skeleton)
            setAccessibilityElement(true)
            setAccessibilityRole(.progressIndicator)
            isHidden = true
            return
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        line.font = .ui(TextSize.body)
        line.textColor = .secondaryLabelColor
        detail.font = .ui(TextSize.caption)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 360
        let row = NSStackView(views: [spinner, line])
        row.spacing = Metrics.gap
        let stack = NSStackView(views: [row, detail])
        stack.orientation = .vertical
        stack.spacing = Metrics.gap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let lifted = stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Metrics.emptyLift)
        lifted.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), lifted,
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Metrics.inset)
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the view with `text` (what it reads: "Reading the databases…") and, with `detail`, what it waits for. Nil
    /// hides it and stops the spinner.
    public func show(_ text: String?, detail: String? = nil) {
        line.stringValue = text ?? ""
        setAccessibilityLabel(text)
        self.detail.stringValue = detail ?? ""
        self.detail.isHidden = detail?.isEmpty ?? true
        if text == nil { waiting?.cancel() }
        guard (text != nil) != showing else { return }
        if text != nil { appear() } else { leave() }
    }

    /// Starts the wait for a first answer by the latency rule (`whileSlow`): `text` shows once the wait has lasted a
    /// second. `show(nil)` ends it, as the answer does.
    /// Limit: a local read that fails says nothing to its panel, so the wait gives itself up after `longest`. The
    /// daemon would have to push the failure for the panel to say it instead.
    public func wait(_ text: String) {
        waiting?.cancel()
        waiting = Task { [weak self] in
            // Cancelled when the answer comes.
            do { try await Task.sleep(for: .seconds(Self.patience)) } catch { return }
            self?.show(text)
            do { try await Task.sleep(for: .seconds(Self.longest)) } catch { return }
            self?.show(nil)
        }
    }

    /// Waits out the rest of `held` when the wait is on screen. Call it before showing the answer, which then doesn't
    /// come up under a wait that has only just appeared.
    public func settled() async {
        guard let shownAt, !isHidden, leaving == nil else { return }
        let left = Self.held - Date.now.timeIntervalSince(shownAt)
        guard left > 0 else { return }
        do { try await Task.sleep(for: .seconds(left)) } catch { return }   // cancelled: its answer isn't shown
    }

    private func appear() {
        leaving = nil
        shownAt = .now
        spinner.startAnimation(nil)
        skeleton?.shimmer(true)
        fadeIn()
    }

    private func leave() {
        shownAt = nil
        leaves += 1
        let ticket = leaves
        let done: @MainActor () -> Void = { [weak self] in
            guard let self, leaving == ticket else { return }
            leaving = nil
            isHidden = true
            spinner.stopAnimation(nil)
            skeleton?.shimmer(false)
        }
        leaving = ticket
        guard !Motion.reduced, window != nil else { return done() }
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = Motion.fast
                animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { done() } })   // AppKit ends the group on the main thread
    }

    /// Fills `area` under `top`, as an empty state does.
    public func place(in area: NSView, under top: NSView? = nil) { pin(in: area, under: top) }

    /// Clicks go through to what's under it.
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The rows a list will show, as shapes: a mark and two lines per row (`Metrics.rowTwoLine`, grown with Text size), as many as fit, with a
/// light passing over them every `Motion.breathe` (still under Reduce Motion).
@MainActor
final class SkeletonRows: NSView {
    private let bars = CAShapeLayer()
    private let light = CAGradientLayer()
    private let lightMask = CAShapeLayer()
    // How long each row's lines are, as a share of the room they have, uneven as names are.
    private static let widths: [CGFloat] = [0.72, 0.55, 0.84, 0.63, 0.78, 0.5, 0.68, 0.6]
    /// The light's band, wholly left of the rows.
    private static let before: [NSNumber] = [-0.4, -0.2, 0]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(bars)
        light.mask = lightMask
        light.startPoint = CGPoint(x: 0, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 0.5)
        light.locations = Self.before   // so under Reduce Motion, where it's still, it stays off the rows
        layer?.addSublayer(light)
        followReduceMotion(#selector(motionChanged))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let path = CGMutablePath(), inset = Metrics.inset, room = bounds.width - 2 * inset
        let line = Metrics.gapWide, under = Metrics.gap   // the height of a name's line, and of its second line
        let mark = Metrics.iconSmall, row = TextSize.of(Metrics.rowTwoLine)   // the rows they stand for grow too
        var top: CGFloat = Metrics.gap
        for width in Self.widths where top + row <= bounds.height {
            let middle = top + row / 2
            path.addEllipse(in: CGRect(x: inset, y: middle - mark / 2, width: mark, height: mark))
            let x = inset + mark + Metrics.gapWide, text = max(0, room - mark - Metrics.gapWide)
            let first = CGRect(x: x, y: middle - line - Metrics.lineGap / 2, width: text * width, height: line)
            let second = CGRect(x: x, y: middle + Metrics.lineGap, width: text * width * 0.6, height: under)
            for bar in [first, second] {
                path.addRoundedRect(in: bar, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2)
            }
            top += row
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // otherwise plain sublayers would ease into their new shape
        bars.frame = bounds
        bars.path = path
        light.frame = bounds
        lightMask.frame = bounds
        lightMask.path = path
        CATransaction.commit()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bars.fillColor = NSColor.quaternaryLabelColor.cgColor
            let glint = NSColor.quaternaryLabelColor.cgColor, none = NSColor.clear.cgColor
            light.colors = [none, glint, none]
        }
    }

    private var shimmering = false
    /// Reduce Motion switched on or off while the rows show stops or starts the light.
    @objc private func motionChanged() { shimmer(shimmering) }

    /// The light passes over the rows while they show; nothing moves under Reduce Motion.
    func shimmer(_ on: Bool) {
        shimmering = on
        light.removeAnimation(forKey: "shimmer")
        guard on, !Motion.reduced else { return }
        // A band a third as wide as the rows, moving from wholly left of them to wholly right.
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = Self.before
        sweep.toValue = [1, 1.2, 1.4]
        sweep.duration = Motion.breathe
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.repeatCount = .infinity
        sweep.beginTime = Motion.beat(Motion.breathe)   // so every list's light moves in step
        light.add(sweep, forKey: "shimmer")
    }
}

/// The same view for SwiftUI: the spinner and its line, as a form's row or, with `.frame(maxHeight: .infinity)`, in
/// the middle of a page.
public struct LoadingLine: View {
    private let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        HStack(spacing: Metrics.gap) {
            ProgressView().controlSize(.small)
            Text(text).font(.ui(TextSize.body)).foregroundStyle(.secondary)
        }
    }
}

extension NSView {
    /// Fills `area` under `top` (its bar), over whatever the area shows.
    func pin(in area: NSView, under top: NSView?) {
        translatesAutoresizingMaskIntoConstraints = false
        area.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: top?.bottomAnchor ?? area.topAnchor),
            bottomAnchor.constraint(equalTo: area.bottomAnchor),
            leadingAnchor.constraint(equalTo: area.leadingAnchor),
            trailingAnchor.constraint(equalTo: area.trailingAnchor)
        ])
    }
}
