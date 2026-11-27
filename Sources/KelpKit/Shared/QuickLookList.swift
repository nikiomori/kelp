import AppKit
import Quartz

/// Quick Look (Space) for a list's selection, `url` read each time the panel asks. The list's controller passes the
/// panel on from its `beginPreviewPanelControl` and `endPreviewPanelControl` (Quick Look's responder chain); `key`
/// gets the keys pressed in the preview first (true: handled).
@MainActor
package final class QuickLookList: NSObject, @preconcurrency QLPreviewPanelDataSource,
    @preconcurrency QLPreviewPanelDelegate
{
    private let url: () -> URL?, key: ((NSEvent) -> Bool)?

    package init(url: @escaping () -> URL?, key: ((NSEvent) -> Bool)? = nil) { (self.url, self.key) = (url, key) }

    package func toggle() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        panel.makeKeyAndOrderFront(nil)
        if panel.dataSource == nil {   // the key window's responder chain didn't lead here
            control(panel)
            panel.reloadData()
        }
    }

    /// Gives this the panel, or with `false` takes it back.
    package func control(_ panel: QLPreviewPanel, _ on: Bool = true) {
        panel.dataSource = on ? self : nil
        panel.delegate = on ? self : nil
    }

    package func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url() == nil ? 0 : 1 }
    package func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url() as NSURL? }
    package func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        event.flatMap { key?($0) } ?? false
    }
}
