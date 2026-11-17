import AppKit
import Core
import DesignKit
import KelpKit

/// A branch's CI in one mark, drawn the way agents' states are: a spinning ring while it runs, an orange ◎ while a
/// deploy waits for someone's approval, a quiet filled ✓ when it passed and you haven't looked, and a red dot when it
/// failed (CI Runs' filled ✕ was the loudest thing in the sidebar and read as a window's close button). When `spelled`,
/// it says "CI" instead.
/// It sits over the image slot of a chip or a badge, and lets clicks through to it. The shell shows it through
/// `FolderCI.mark`.
@MainActor
final class CIMark: NSView {
    private let agentLike = StatusMark(size: 12), word = NSTextField(labelWithString: "CI")
    var state: CIRuns.State? { didSet { if state != oldValue { update() } } }
    /// Under the pointer (a sidebar row's CI badge): a failure says "CI" where its dot was, as the changes dot shows its
    /// counts.
    var spelled = false { didSet { if spelled != oldValue { update() } } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        word.font = .ui(TextSize.caption, weight: .semibold)
        word.textColor = .textRed
        for part in [agentLike, word] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
            NSLayoutConstraint.activate([
                part.centerXAnchor.constraint(equalTo: centerXAnchor),
                part.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 12), heightAnchor.constraint(equalToConstant: 12)
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// The ring says nothing: its words belong to an agent, while the chip or badge it sits on says what CI does.
    override func accessibilityChildren() -> [Any]? { [] }

    /// How much wider than its 12 pt the mark is while it says "CI": the room a row must keep for it.
    var overhang: CGFloat { spelled && state == .failed ? max(0, ceil(word.intrinsicContentSize.width) - 12) : 0 }

    private func update() {
        isHidden = state == nil
        word.isHidden = state != .failed || !spelled
        needsDisplay = true
        agentLike.status =
            switch state {
            case .running: .working
            case .waiting: .waiting
            case .passed: .done
            case .failed, nil: nil
            }
    }

    /// The failure's dot, 6 pt in the mark's 12: drawn here, so it follows the appearance as text colours do.
    override func draw(_ dirtyRect: NSRect) {
        guard state == .failed, !spelled else { return }
        NSColor.textRed.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: bounds.width / 4, dy: bounds.height / 4)).fill()
    }

    /// One for the shell (`FolderCI.mark`): the view, and what shows a state in it, answering its `overhang`.
    static func made() -> (view: NSView, show: @MainActor (CIRuns.State?, Bool) -> CGFloat) {
        let mark = CIMark()
        return (
            mark,
            { state, spelled in
                mark.state = state
                mark.spelled = spelled
                return mark.overhang
            }
        )
    }
}
