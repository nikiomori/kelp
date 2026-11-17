import AppKit
import DesignKit

/// An agent's logo with its state in a corner cut out of it, as macOS marks a person's status on their picture. The
/// chats of a folded project (AgentStack) and a chat's own row (when Agent icons is Always) draw it the same way.
@MainActor
final class AgentFace: NSView {
    static let side: CGFloat = 14
    /// The mark for the state. The caller sets it as on any StatusMark, then calls `cut()`.
    let mark = StatusMark(size: 8)
    private let logo = NSImageView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        logo.frame = bounds
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.wantsLayer = true
        mark.announces = false
        mark.frame = NSRect(x: Self.side - 6, y: -2, width: 8, height: 8)
        addSubview(logo)
        addSubview(mark)
    }
    required init?(coder: NSCoder) { fatalError() }

    var image: NSImage? {
        get { logo.image }
        set { if logo.image !== newValue { logo.image = newValue } }   // setting the image draws it again
    }

    /// Cuts the logo away around the mark while the mark shows, leaving a clear ring, whatever the sidebar's material
    /// shows through.
    func cut() {
        guard !mark.isHidden else {
            logo.layer?.mask = nil
            return
        }
        guard logo.layer?.mask == nil else { return }
        let hole = CGPath(ellipseIn: mark.frame.insetBy(dx: -1.5, dy: -1.5), transform: nil), path = CGMutablePath()
        path.addRect(logo.bounds)
        path.addPath(hole)
        let mask = CAShapeLayer()
        mask.path = path
        mask.fillRule = .evenOdd
        logo.layer?.mask = mask
    }
}
