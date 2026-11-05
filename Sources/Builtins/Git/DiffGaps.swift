import AppKit
import DesignKit
import Core
import KelpKit
import WorkbenchKit

/// The unchanged lines between two changes: a capsule saying how many and in which function (git's own guess, from the
/// next hunk's header); a click shows them in place, read from the file as the diff shows it.
extension DiffViewController {
    func gapRow(file f: Int, from: Int, lines n: Int, context: String) -> NSView {
        let title = String(localized: "⋯  \(n) unchanged lines") + (context.isEmpty ? "" : "  ·  " + context)
        let b = ClosureButton(title: title) { [weak self] in self?.openGap(file: f, from: from, lines: n) }
        b.bezelStyle = .inline
        b.controlSize = .small
        b.lineBreakMode = .byTruncatingTail
        b.toolTip = String(localized: "Show These Lines")
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [b])
        row.edgeInsets = NSEdgeInsets(top: 0, left: Self.codeIndent, bottom: 0, right: Metrics.gapWide)   // under the code
        return row
    }

    private func openGap(file f: Int, from: Int, lines n: Int) {
        guard diffs.indices.contains(f) else { return }
        let path = diffs[f].path
        var whole = diffRequest()
        whole.file = path
        whole.context = 1_000_000   // the file whole, as one hunk
        Task {
            let shown = await app.call(whole)?.first { $0.path == path }?.hunks.flatMap(\.lines)
                .filter { $0.kind == .context && ($0.newLine.map { (from..<from + n).contains($0) } ?? false) } ?? []
            guard shown.count == n else { NSSound.beep(); return }   // the file moved on since: the next read shows it
            opened[DiffRows.gapKey(path, from)] = shown
            rebuildRows()
        }
    }
}
