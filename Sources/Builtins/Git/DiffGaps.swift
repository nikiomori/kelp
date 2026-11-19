import AppKit
import Core
import DesignKit
import KelpKit

/// The unchanged lines between two changes, as a capsule saying how many and in which function (git's own guess, from
/// the next hunk's header). A click shows the lines in place, read from the file as the diff shows it.
extension DiffViewController {
    func gapRow(file: Int, from: Int, lines count: Int, context: String) -> NSView {
        let title = String(localized: "⋯  \(count) unchanged lines") + (context.isEmpty ? "" : "  ·  " + context)
        let button = ClosureButton(title: title) { [weak self] in self?.openGap(file: file, from: from, lines: count) }
        button.bezelStyle = .inline
        button.controlSize = .small
        button.lineBreakMode = .byTruncatingTail
        button.toolTip = String(localized: "Show These Lines")
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [button])
        row.edgeInsets = NSEdgeInsets(top: 0, left: Self.codeIndent, bottom: 0, right: Metrics.gapWide)   // under code
        return row
    }

    private func openGap(file: Int, from: Int, lines count: Int) {
        guard diffs.indices.contains(file) else { return }
        let path = diffs[file].path
        var whole = diffRequest()
        whole.file = path
        whole.context = 1_000_000   // asks for the whole file, as one hunk
        Task {
            let shown =
                await app.call(whole)?.first { $0.path == path }?.hunks.flatMap(\.lines)
                .filter { $0.kind == .context && ($0.newLine.map { (from..<from + count).contains($0) } ?? false) }
                ?? []
            guard shown.count == count else {
                NSSound.beep()
                return
            }   // the file moved on since, and the next read shows it
            opened[DiffRows.gapKey(path, from)] = shown
            rebuildRows()
        }
    }
}
