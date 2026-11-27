import AppKit
import KelpKit
import Quartz

/// Quick Look (Space) for the chosen task: the page it grew into, or the page it is on, as Artifacts Overview shows a
/// page and Files a file.
extension TasksController {
    func togglePreview() { quickLook.toggle() }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    // QuickLook asks the responder chain on the main thread; its informal protocol isn't annotated.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook.control(panel) }   // QLPreviewPanel's callback, on the main thread
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook.control(panel, false) }   // QLPreviewPanel's callback, on the main thread
    }
}
