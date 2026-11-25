import AppKit
import WebKit

/// A web view that lets its tab take files dropped from Finder first (`onFiles`, with where they were dropped in the
/// page's own points); what the tab doesn't take goes to WebKit as before.
final class DropWebView: WKWebView {
    var onFiles: (([URL], NSPoint) -> Bool)?

    private func files(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFiles != nil && !files(sender).isEmpty ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFiles != nil && !files(sender).isEmpty ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        let inPage = NSPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        if let onFiles, case let urls = files(sender), !urls.isEmpty, onFiles(urls, inPage) { return true }
        return super.performDragOperation(sender)
    }
}
