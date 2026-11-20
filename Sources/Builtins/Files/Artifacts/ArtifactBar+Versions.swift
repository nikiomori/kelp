import AppKit
import Core
import DesignKit
import KelpKit

/// The kept versions of a page, in its bar. This steps back and forward through them, shows one in the preview and
/// restores it, lists them in a menu, and picks the version a doc's changes are counted from.
extension ArtifactBar {
    /// Picks the version a doc's changes are counted from, which is the one the agent's last turn started from. That is
    /// the version before the last kept one, or the last kept one while a turn is still writing the file (because the
    /// file then differs from it).
    func followBaseline(versions: [ArtifactVersion], live: Bool) {
        let n = (live ? versions.last : versions.dropLast().last)?.n
        guard n != baselineN else { return }
        baselineN = n
        guard let n else { return markdown.baseline = nil }
        Task {
            let file = await app.quiet(FilesRead(path: Artifacts.versionPath(target: path, n)))
            if baselineN == n { markdown.baseline = file?.text }
        }
    }

    /// The bar's buttons that commands repeat (`Builtins.files`), by command id. A command runs only while its button
    /// shows on the page in front and can be pressed (Present still counts while a narrow pane keeps it in ⋯).
    func button(for id: String) -> NSControl? {
        switch id {
        case "artifact.present": present
        case "artifact.olderVersion": back
        case "artifact.newerVersion": forward
        case "artifact.showLatest": latest
        case "artifact.restore": restore
        case "artifact.update": refresh
        default: nil
        }
    }

    func step(_ by: Int) {
        let index = (shown ?? entries.count - 1) + by
        guard entries.indices.contains(index) else { return }
        show(index == entries.count - 1 ? nil : index)
    }

    /// Shows entry `index` in the preview, or the current file when `index` is nil.
    func show(_ index: Int?) {
        guard let index, let version = entries[index].version else {
            shownN = nil
            markdown.showVersion(nil)
            return update()
        }
        Task {
            guard let file = await app.call(FilesRead(path: Artifacts.versionPath(target: path, version.n))) else {
                return
            }
            shownN = version.n
            markdown.showVersion(file.text)
            update()
        }
    }

    func restoreShown() {
        guard let text = markdown.shownVersion else { return }
        markdown.restore(text)
        show(nil)
    }

    func showVersions() {
        let menu = NSMenu()
        for (index, entry) in entries.enumerated().reversed() {
            let when = [
                Self.time(entry.at),
                entry.version == nil && index == entries.count - 1 && !status.stringValue.isEmpty && shown == nil
                    ? String(localized: "now writing") : nil
            ].compactMap { $0 }.joined(separator: " · ")
            let item = menu.add("\(index + 1)  \(entry.label)") { [weak self] in
                self?.show(index == (self?.entries.count ?? 0) - 1 ? nil : index)
            }
            item.state = index == (shown ?? entries.count - 1) ? .on : .off
            item.toolTip = when
            item.attributedTitle = Self.menuTitle("\(index + 1)  \(entry.label)", when)
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Kelp keeps the last \(Artifacts.keptVersions) turns"), action: nil,
            keyEquivalent: ""
        ).isEnabled = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: count.bounds.height + 4), in: count)
    }

    static func time(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        let date = Date(timeIntervalSince1970: seconds)
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }

    static func menuTitle(_ title: String, _ detail: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        guard !detail.isEmpty else { return text }
        text.append(
            NSAttributedString(
                string: "\n" + detail,
                attributes: [.font: NSFont.ui(TextSize.caption), .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }
}
