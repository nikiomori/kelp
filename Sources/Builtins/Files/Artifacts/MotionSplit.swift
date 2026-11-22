import AppKit
import DesignKit

/// The stage over the studio, with the line between them dragged to give either more room. The studio's height is
/// kept on this Mac; a double click on the line folds the studio to its row of controls, or opens it again.
@MainActor
final class MotionSplit: NSSplitView, NSSplitViewDelegate {
    private let studio: NSView
    /// The studio's height folded: its row of controls and the line over it.
    private let folded = Metrics.contentBar + 1
    private var opened: CGFloat = 0

    init(stage: NSView, studio: NSView) {
        self.studio = studio
        super.init(frame: .zero)
        isVertical = false
        dividerStyle = .thin
        delegate = self
        addArrangedSubview(stage)
        addArrangedSubview(studio)
        setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)   // the stage gives way when the window changes
        setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        autosaveName = "motion.studio"
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Laid out the first time with no height kept: the studio as tall as its lanes, the stage the rest.
    private var placed = false
    override func layout() {
        super.layout()
        guard !placed, bounds.height > 0 else { return }
        placed = true
        let kept = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(autosaveName ?? "")") != nil
        if !kept || studio.frame.height > bounds.height - Metrics.rowSection * 4 {
            setPosition(bounds.height - studio.fittingSize.height - dividerThickness, ofDividerAt: 0)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int)
        -> CGFloat
    {
        max(proposed, Metrics.rowSection * 4)   // the stage keeps a little room
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int)
        -> CGFloat
    {
        min(proposed, bounds.height - folded)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let line = NSRect(
            x: 0, y: studio.frame.minY - dividerThickness - 2, width: bounds.width, height: dividerThickness + 4)
        guard event.clickCount == 2, line.contains(p) else { return super.mouseDown(with: event) }
        let height = studio.frame.height
        if height > folded + 1 {
            opened = height
            setPosition(bounds.height - folded - dividerThickness, ofDividerAt: 0)
        } else {
            setPosition(bounds.height - max(opened, Metrics.row * 8) - dividerThickness, ofDividerAt: 0)
        }
    }
}
