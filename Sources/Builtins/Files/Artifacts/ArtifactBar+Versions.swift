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
        Task { await markdown.restore(text) }
        show(nil)
    }

    /// Brings version `version` back as the page, then keeps it as a new version that says so.
    func restore(_ version: ArtifactVersion) async {
        guard let file = await app.call(FilesRead(path: Artifacts.versionPath(target: path, version.n))) else { return }
        show(nil)
        guard await markdown.restore(file.text) else { return }
        await app.call(ArtifactKeepRestored(path: path, from: version.n))
    }

    /// The page's agent, by name, and its chat while it hasn't ended.
    var agentName: String? { item?.session.flatMap(app.session).flatMap { app.catalog.name($0.agent) } }
    var chat: String? { item?.session.flatMap { app.session($0)?.status == .exited ? nil : $0 } }

    /// The column of versions beside the page (its "N of M"), opened or closed.
    func showVersions() {
        if let open = versionsPanel { return open.removeFromSuperview() }
        markdown.split.addArrangedSubview(VersionsPanel(bar: self))
    }

    var versionsPanel: VersionsPanel? { markdown.split.arrangedSubviews.last as? VersionsPanel }

    static func time(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        let date = Date(timeIntervalSince1970: seconds)
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }
}
