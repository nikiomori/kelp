// Tabs dropped between tabs: where the insertion mark goes and which index a drop lands at.
import AppKit
import Core
import DesignKit

extension NSPasteboard.PasteboardType { static let kelpTab = NSPasteboard.PasteboardType("dev.kelp.tab") }

extension TabStrip {
    // MARK: drops between tabs
    private func index(at point: NSPoint) -> Int {
        let pointX = stack.convert(point, from: nil).x
        return buttons.firstIndex { $0.frame.midX > pointX } ?? buttons.count
    }
    private func showInsertion(_ position: Int) {
        let local = position < buttons.count ? buttons[position].frame.minX - 1 : (buttons.last?.frame.maxX ?? 6)
        let markX = convert(NSPoint(x: local, y: 0), from: stack).x
        let frame = NSRect(x: markX, y: 4, width: 2, height: bounds.height - 8)
        if insertion.isHidden {   // it comes in where it's needed, then glides from gap to gap
            insertion.frame = frame
            insertion.isHidden = false
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.duration(Motion.fast)
                insertion.animator().frame = frame
            }
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: .kelpTab) != nil else { return [] }
        showInsertion(index(at: sender.draggingLocation))
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { insertion.isHidden = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        insertion.isHidden = true
        guard let id = sender.draggingPasteboard.string(forType: .kelpTab) else { return false }
        onDropTab?(id, index(at: sender.draggingLocation))
        return true
    }
}
