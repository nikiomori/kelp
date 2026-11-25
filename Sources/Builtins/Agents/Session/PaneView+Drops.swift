import AppKit
import KelpKit
import TerminalKit

/// Drops on an agent's pane: files, images and text go into its prompt.
extension PaneView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHint.show(over: self)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHint.hide() }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHint.hide() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var paths = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.map { TerminalPaths.onHost($0.path) } ?? []
        if paths.isEmpty, let png = TerminalPaste.savedImage(pb) { paths = [png] }
        if paths.isEmpty, let text = pb.string(forType: .string) {
            insert(text)
            return true
        }
        guard !paths.isEmpty else { return false }
        insert(TerminalPaste.paths(paths))
        focus()
        return true
    }
}
