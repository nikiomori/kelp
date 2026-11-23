import AppKit
import Core
import DesignKit

/// Where the layers' blocks go: the shown root across the top, its folders and files under it, each as wide as the
/// files it holds (the count, not the touches: a file read again and again doesn't crowd out the folders read once).
/// Siblings too narrow to see are merged into one block at their parent's end.
enum Icicle {
    struct Block: Equatable {
        /// The node's path, or nil for merged small siblings.
        var path: String?
        var rect: CGRect
        var depth: Int
        /// For merged siblings, how many.
        var merged = 0
    }

    /// A row of blocks: how tall, and the gap under it.
    struct Row { var height: CGFloat, gap: CGFloat }

    static func layout(_ root: WorkNode, width: CGFloat, rows: Int, row: Row, narrowest: CGFloat) -> [Block] {
        let (rowHeight, gap) = (row.height, row.gap)
        var blocks: [Block] = []
        func lay(_ node: WorkNode, x: CGFloat, width: CGFloat, depth: Int) {
            blocks.append(
                Block(
                    path: node.path,
                    rect: CGRect(x: x, y: CGFloat(depth) * (rowHeight + gap), width: width, height: rowHeight),
                    depth: depth))
            guard depth + 1 < rows, !node.isFile else { return }
            let total = CGFloat(max(node.weight, 1))
            var cursor = x, small = (count: 0, width: CGFloat(0))
            for child in node.children where child.weight > 0 {
                let w = width * CGFloat(child.weight) / total
                if w < narrowest {
                    small = (small.count + 1, small.width + w)
                    continue
                }
                lay(child, x: cursor, width: w, depth: depth + 1)
                cursor += w
            }
            if small.count > 0 {
                let rect = CGRect(
                    x: cursor, y: CGFloat(depth + 1) * (rowHeight + gap), width: small.width, height: rowHeight)
                blocks.append(Block(path: nil, rect: rect, depth: depth + 1, merged: small.count))
            }
        }
        lay(root, x: 0, width: width, depth: 0)
        return blocks
    }
}

/// The Work panel's layers. A click selects a block (the list under it follows), a double-click or Return goes into it,
/// ⌘↑ comes back out; the arrows move between blocks. Each block is an element VoiceOver reads.
@MainActor
final class IcicleView: NSView, NSViewToolTipOwner {
    var root = WorkNode(path: "", name: "") {
        didSet { if root != oldValue { relayout(flashNew: oldValue.path == root.path && !oldValue.children.isEmpty) } }
    }
    /// Blocks that just came in, lit for as long as Needs You flashes.
    private let flash = Flash()
    var selected: String? { didSet { if selected != oldValue { needsDisplay = true } } }
    /// Where the agent is now, ringed while it works.
    var now: String? { didSet { if now != oldValue { needsDisplay = true } } }
    var onSelect: (String) -> Void = { _ in }
    var onZoom: (String?) -> Void = { _ in }   // nil: out by one
    var onOpen: (String) -> Void = { _ in }
    /// The agents' names, by their index in the work, for tooltips and VoiceOver.
    var agentNames: [String] = []

    /// The rows shown under the root, which isn't one: the heading above names it.
    static let rows = 3
    private(set) var blocks: [Icicle.Block] = []
    private var usedRows = 1
    private var elements: [NSAccessibilityElement] = []
    private var rowHeight: CGFloat { TextSize.of(Metrics.row) - Metrics.lineGap }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// As tall as the rows the tree fills, up to `rows`.
    override var intrinsicContentSize: NSSize {
        let used = CGFloat(min(Self.rows, max(1, (blocks.map(\.depth).max() ?? 0) + 1)))
        return NSSize(width: NSView.noIntrinsicMetric, height: used * (rowHeight + Metrics.lineGap) - Metrics.lineGap)
    }

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout(flashNew: Bool = false) {
        let before = Set(blocks.compactMap(\.path))
        let step = rowHeight + Metrics.lineGap
        blocks = Icicle.layout(
            root, width: bounds.width, rows: Self.rows + 1, row: .init(height: rowHeight, gap: Metrics.lineGap),
            narrowest: Metrics.gapTight
        ).filter { $0.depth > 0 }.map { block in
            var block = block
            block.depth -= 1
            block.rect.origin.y -= step
            return block
        }
        removeAllToolTips()
        for (index, block) in blocks.enumerated() {
            addToolTip(block.rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
        elements = blocks.map(element)
        // Its height changes only with the rows used: asking again from inside layout would lay it out again.
        let rows = (blocks.map(\.depth).max() ?? 0) + 1
        if rows != usedRows {
            usedRows = rows
            invalidateIntrinsicContentSize()
        }
        if flashNew {
            flash.start(Set(blocks.compactMap(\.path)).subtracting(before)) { [weak self] in self?.needsDisplay = true }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.ui(TextSize.micro, weight: .medium), plain = NSFont.ui(TextSize.micro)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let nowBlock = nowBlock
        for block in blocks {
            let rect = block.rect.insetBy(dx: Metrics.lineGap / 2, dy: 0)
            guard rect.width >= 1 else { continue }
            let shape = NSBezierPath(roundedRect: rect, xRadius: Metrics.radiusXS, yRadius: Metrics.radiusXS)
            let node = block.path.flatMap { root.node(at: $0) }
            fill(for: node).setFill()
            shape.fill()
            if block.path == selected, block.path != nil { ring(rect, .keyboardFocusIndicatorColor) }
            // Where the agent is now: a dot at the end of the deepest block it is in, not a second ring.
            if block == nowBlock {
                let r = Metrics.dotRadius
                NSColor.labelColor.setFill()
                NSBezierPath(
                    ovalIn: NSRect(
                        x: rect.maxX - Metrics.gapTight - 2 * r, y: rect.midY - r, width: 2 * r, height: 2 * r)
                ).fill()
            }
            if let path = block.path, flash.lit.contains(path) { ring(rect, .agentEdited) }
            let name = node?.name ?? (block.merged > 0 ? "…" : "")
            // A block too narrow for its whole name gets none (a cut name like "A…ta" reads as noise): the name is in
            // its tooltip and the list.
            let inset = Metrics.gapTight + Metrics.lineGap / 2
            let room = rect.width - 2 * inset
            let whole = NSAttributedString(string: name, attributes: [.font: node?.isFile == false ? font : plain])
            guard whole.size().width <= room, !name.isEmpty else { continue }
            let text = NSAttributedString(
                string: name,
                attributes: [
                    .font: node?.isFile == false ? font : plain, .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: style
                ])
            let height = text.size().height
            text.draw(
                in: NSRect(
                    x: rect.minX + inset, y: rect.midY - height / 2, width: rect.width - 2 * inset, height: height))
        }
    }

    private var nowBlock: Icicle.Block? {
        guard let now else { return nil }
        return blocks.filter { $0.path.map { now == $0 || Paths.relative(now, to: $0) != nil } == true }.max {
            $0.depth < $1.depth
        }
    }

    private func fill(for node: WorkNode?) -> NSColor {
        guard let node else { return .fillRest }
        if node.isFile { return node.edited ? .agentEdited : .fillSelected }
        return node.edited ? .agentEditedFolder : .fillHover
    }

    private func ring(_ rect: NSRect, _ color: NSColor) {
        let path = NSBezierPath(
            roundedRect: rect.insetBy(dx: Metrics.lineGap / 2, dy: Metrics.lineGap / 2),
            xRadius: Metrics.radiusXS - Metrics.lineGap / 2, yRadius: Metrics.radiusXS - Metrics.lineGap / 2)
        path.lineWidth = Metrics.strokeBold
        color.setStroke()
        path.stroke()
    }

    // MARK: Pointer and keys

    private func block(at point: NSPoint) -> Icicle.Block? { blocks.last { $0.rect.contains(point) } }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let hit = block(at: convert(event.locationInWindow, from: nil)) else { return }
        guard let path = hit.path else {
            // Merged small blocks: into their parent, where they get room (the top row's parent is the root shown).
            let parent = blocks.first {
                $0.depth == hit.depth - 1 && $0.rect.minX <= hit.rect.minX && $0.rect.maxX >= hit.rect.maxX
            }
            // In the top row their parent is the root shown: picking it lists them all below.
            return parent?.path.map { onZoom($0) } ?? onSelect(root.path)
        }
        if event.clickCount == 2 {
            if root.node(at: path)?.isFile == true { onOpen(path) } else { onZoom(path) }
        } else {
            onSelect(path)
        }
    }

    override func keyDown(with event: NSEvent) {
        // The block picked, else the first named one: a merged "…" block is never where the keys start.
        let current = blocks.first { $0.path != nil && $0.path == selected } ?? blocks.first { $0.path != nil }
        guard let current else { return super.keyDown(with: event) }
        switch event.specialKey {
        case .leftArrow?, .rightArrow?:
            let row = blocks.filter { $0.depth == current.depth && $0.path != nil }
            guard !row.isEmpty else { return }
            let index = row.firstIndex { $0.path == current.path } ?? 0
            let next = row[max(0, min(row.count - 1, index + (event.specialKey == .leftArrow ? -1 : 1)))]
            next.path.map(onSelect)
        case .upArrow?:
            if event.modifierFlags.contains(.command) { return onZoom(nil) }
            blocks.first {
                $0.depth == current.depth - 1 && $0.rect.minX <= current.rect.midX && $0.rect.maxX >= current.rect.midX
            }?.path.map(onSelect)
        case .downArrow?:
            // Its first child: under it, not the next block's.
            blocks.first {
                $0.depth == current.depth + 1 && $0.path != nil
                    && $0.rect.minX >= current.rect.minX - Metrics.lineGap / 4
                    && $0.rect.minX < current.rect.maxX
            }?.path.map(onSelect)
        case .carriageReturn?, .enter?:
            guard let path = current.path else { return }
            if root.node(at: path)?.isFile == true { onOpen(path) } else { onZoom(path) }
        default: super.keyDown(with: event)
        }
    }

    // MARK: Tooltips and VoiceOver

    func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?
    ) -> String {
        let index = Int(bitPattern: data) - 1
        guard blocks.indices.contains(index) else { return "" }
        return describe(blocks[index])
    }

    private func describe(_ block: Icicle.Block) -> String {
        guard let path = block.path, let node = root.node(at: path) else {
            return String(localized: "\(block.merged) more")
        }
        return WorkWords.describe(node, agents: agentNames)
    }

    private func element(_ block: Icicle.Block) -> NSAccessibilityElement {
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.button)
        element.setAccessibilityLabel(describe(block))
        element.setAccessibilityFrameInParentSpace(block.rect)
        element.setAccessibilityParent(self)
        element.setAccessibilitySelected(block.path == selected)
        return element
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { String(localized: "Where the agent worked") }
    override func accessibilityChildren() -> [Any]? { elements }
}
