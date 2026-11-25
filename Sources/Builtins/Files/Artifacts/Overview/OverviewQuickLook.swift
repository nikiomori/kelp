import AppKit
import Core
import Quartz

/// Quick Look on Artifacts Overview (Space, or the page's menu): the page as it is now, then its kept versions, newest
/// first, which Quick Look's arrows step through. Each says which version it is and who made it. A page on claude.ai
/// has only Kelp's copy of it, so only that shows.
@MainActor
final class OverviewQuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource {
    private var items: [Item] = []
    private var shown: String?

    final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(_ path: String, _ title: String) {
            previewItemURL = URL(fileURLWithPath: path)
            previewItemTitle = title
        }
    }

    /// What Quick Look steps through for `item`: the page now, then its versions newest first.
    static func items(_ item: ArtifactItem, title: String) -> [(path: String, title: String)] {
        guard let preview = item.preview else { return [] }
        let versions = (item.url == nil ? item.versions ?? [] : []).reversed().map { version in
            let who =
                version.restored != nil
                ? String(localized: "restored")
                : version.byUser == true ? String(localized: "you") : String(version.label.prefix(40))
            return (
                Artifacts.versionPath(target: item.target, version.n),
                String(localized: "\(title) · version \(version.n), \(who)")
            )
        }
        return [(preview, title)] + versions
    }

    /// Shows `item` in Quick Look, or puts Quick Look away when it already shows it.
    func toggle(_ item: ArtifactItem, title: String) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, shown == item.target {
            panel.orderOut(nil)
            return
        }
        shown = item.target
        items = Self.items(item, title: title).map { Item($0.path, $0.title) }
        guard !items.isEmpty else { return NSSound.beep() }
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard shown != nil, let panel = QLPreviewPanel.shared(), panel.isVisible, panel.dataSource === self else {
            return
        }
        panel.orderOut(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        items.indices.contains(index) ? items[index] : nil
    }
}
