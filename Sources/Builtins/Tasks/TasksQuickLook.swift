import AppKit
import KelpKit
import Quartz

/// Quick Look (Space) for the chosen task: the page it grew into, or the page it is on, as Artifacts Overview shows a
/// page and Files a file.
extension TasksController: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func togglePreview() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        panel.makeKeyAndOrderFront(nil)
        if panel.dataSource == nil {   // the key window's responder chain didn't lead here
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
        }
    }
    private var previewURL: URL? {
        list.chosen.map { URL(fileURLWithPath: TaskActions.pageFile($0)) }
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    // QuickLook asks the responder chain on the main thread; its informal protocol isn't annotated.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {   // QLPreviewPanel's callback, on the main thread
            panel.dataSource = self
            panel.delegate = self
        }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {   // QLPreviewPanel's callback, on the main thread
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURL as NSURL? }
}
