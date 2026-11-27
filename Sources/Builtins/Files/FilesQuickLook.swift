import AppKit
import KelpKit
import Quartz

/// Quick Look (Space) for the tree's selection; ↑↓ in the preview walk the tree, like Finder.
extension FilesPanel {
    func makeQuickLook() -> QuickLookList {
        QuickLookList { [weak self] in
            guard let self, let node = outline.item(atRow: outline.selectedRow) as? FileNode else { return nil }
            return URL(fileURLWithPath: root).appendingPathComponent(node.path)
        } key: { [weak self] event in
            guard event.type == .keyDown, [125, 126].contains(event.keyCode) else { return false }
            self?.outline.keyDown(with: event)
            return true
        }
    }
    @objc func togglePreview() { quickLook.toggle() }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    // QuickLook asks the responder chain on the main thread; its informal protocol isn't annotated.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook.control(panel) }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook.control(panel, false) }
    }
}
