import AppKit
import Core
import KelpKit
import Quartz

/// Quick Look (Space, or the row's menu) for the picked page: its file, or Kelp's copy of a page on a service.
extension ArtifactsPanel: @preconcurrency QLPreviewPanelDataSource {
    func togglePreview() {
        guard let (item, _) = item(at: table.selectedRow) else { return }
        quickLook(item)
    }
    func quickLook(_ item: ArtifactItem) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, looked == item.preview {
            panel.orderOut(nil)
            return
        }
        looked = item.preview
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { looked == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        looked.map { URL(fileURLWithPath: $0) as NSURL }
    }
}
