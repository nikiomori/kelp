import AppKit
import Core
import DesignKit

/// The Map tab's drawing: the agent at the left, curves to its project's folders and files and, below a line, to what
/// it reached outside. A path to an edit is blue. The pointer on a node lights its path and dims the rest; a click
/// opens a file or a site, or unfolds a folded folder; the arrows walk the tree. Each node is an element VoiceOver
/// reads.
@MainActor
final class WorkMapView: NSView {
    var nodes: [MapNode] = [] { didSet { if nodes != oldValue { relayout(flashNew: !oldValue.isEmpty) } } }
    var agentIcon: NSImage?
    var icons: [NSImage?] = []   // each agent's logo, by its index in the work
    var names: [String] = []
    /// The work's agents, to tell a subagent from the session's own (`AgentMarks`).
    var agents: [AgentWork.Agent] = []
    var now: String? { didSet { if now != oldValue { needsDisplay = true } } }
    var selected: String? { didSet { if selected != oldValue { needsDisplay = true } } }
    var onActivate: (MapNode) -> Void = { _ in }
    var onHover: (MapNode?, NSRect) -> Void = { _, _ in }

    private var at: [String: CGPoint] = [:]
    private var hits: [(id: String, rect: NSRect)] = []
    private var hovered: String? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var lit: Set<String> = []   // the hovered node's path to the agent
    private var flashing: Set<String> = []
    private var elements: [NSAccessibilityElement] = []
    private let font = NSFont.ui(TextSize.row), bold = NSFont.ui(TextSize.row, weight: .medium)
    private let caption = NSFont.uiDigits(TextSize.caption)
    private var step: CGFloat { TextSize.of(Metrics.row) + Metrics.gapTight }
    private var pad: CGFloat { Metrics.pageInset }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func relayout(flashNew: Bool) {
        let before = Set(at.keys)
        at = NodeTree.layout(nodes, width: labelWidth, step: step, gap: Metrics.blockGap + Metrics.inset)
        if flashNew {
            flashing = Set(at.keys).subtracting(before)
            // The new nodes light up for as long as Needs You flashes, then go back to plain.
            if !flashing.isEmpty, !Motion.reduced {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Motion.flash
                    animator().alphaValue = 1
                } completionHandler: { [weak self] in
                    self?.flashing = []
                    self?.needsDisplay = true
                }
            } else {
                flashing = []
            }
        }
        let maxX = nodes.map { (at[$0.id]?.x ?? 0) + labelWidth($0) }.max() ?? 0
        let maxY = at.values.map(\.y).max() ?? 0
        setFrameSize(NSSize(width: maxX + 2 * pad + Metrics.blockGap, height: maxY + 2 * pad + step))
        hits = nodes.compactMap { node in point(node.id).map { (node.id, hitRect(node, $0)) } }
        elements = nodes.compactMap(element)
        needsDisplay = true
    }

    private func point(_ id: String) -> CGPoint? {
        at[id].map { CGPoint(x: $0.x + pad + Metrics.iconMenu / 2, y: $0.y + pad + step / 2) }
    }

    /// How wide a node's column must be for it: a folder's name sits over its dot, a file's words run on its right.
    private func labelWidth(_ node: MapNode) -> CGFloat {
        switch node.kind {
        case .agent: return Metrics.iconMenu
        case .group, .folder: return text(node).size().width
        default:
            let logos =
                CGFloat(AgentMarks.of(node.agents, agents: agents).count + 1) * (Metrics.iconSmall + Metrics.lineGap)
            let badge = node.place?.worktree.map { badgeText($0).size().width + Metrics.gap * 2 } ?? 0
            return Metrics.inset + text(node).size().width + badge + logos + Metrics.gap
        }
    }

    private func text(_ node: MapNode) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if let prefix = node.prefix {
            out.append(.init(string: prefix, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let quiet = [.more, .folded].contains(node.kind) || node.place?.kind == .own
        let base: [NSAttributedString.Key: Any] = [
            .font: [.group, .folder].contains(node.kind) ? bold : font,
            .foregroundColor: quiet ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        out.append(.init(string: node.label, attributes: base))
        if !node.detail.isEmpty {
            out.append(
                .init(
                    string: "  " + node.detail,
                    attributes: [.font: caption, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return out
    }

    private func badgeText(_ worktree: String) -> NSAttributedString {
        NSAttributedString(
            string: "⎇ " + WorkWords.worktree(worktree),
            attributes: [.font: NSFont.ui(TextSize.micro), .foregroundColor: NSColor.secondaryLabelColor])
    }

    private func hitRect(_ node: MapNode, _ p: CGPoint) -> NSRect {
        let r = Metrics.iconSmall
        if [.group, .folder].contains(node.kind) {
            let size = text(node).size()
            return NSRect(
                x: p.x - r, y: p.y - size.height - r, width: max(size.width + r, 2 * r), height: size.height + 2 * r)
        }
        return NSRect(x: p.x - r, y: p.y - r, width: labelWidth(node) + r, height: 2 * r)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The line between the project and what is outside: halfway from the project's last row to the outside's first.
        let outsideRows = nodes.filter { $0.parent == "outside" }.compactMap { point($0.id)?.y }
        let projectRows = nodes.filter { ![.agent, .group].contains($0.kind) && $0.parent != "outside" }.compactMap {
            point($0.id)?.y
        }
        if let first = outsideRows.min(), let last = projectRows.max(), let left = point("outside")?.x {
            let y = (first + last) / 2, line = NSBezierPath()
            line.move(to: NSPoint(x: left - Metrics.inset, y: y))
            line.line(to: NSPoint(x: bounds.maxX - pad, y: y))
            line.setLineDash([Metrics.gapTight, Metrics.gapTight], count: 2, phase: 0)
            NSColor.separatorColor.setStroke()
            line.stroke()
        }
        for node in nodes {
            guard let parent = node.parent, let from = point(parent), let to = point(node.id) else { continue }
            let path = NSBezierPath()
            path.move(to: NSPoint(x: from.x + Metrics.gap, y: from.y))
            let midX = (from.x + to.x) / 2
            path.curve(
                to: NSPoint(x: to.x - Metrics.gap, y: to.y), controlPoint1: NSPoint(x: midX, y: from.y),
                controlPoint2: NSPoint(x: midX, y: to.y))
            let blue = node.edited, on = lit.isEmpty || lit.contains(node.id)
            path.lineWidth = blue || lit.contains(node.id) ? Metrics.lineGap : 1.2
            (lit.contains(node.id) ? NSColor.themeAccent : blue ? NSColor.agentEdited : NSColor.tertiaryLabelColor)
                .withAlphaComponent(on ? 1 : Metrics.paneDim / 2).setStroke()
            path.stroke()
        }
        for node in nodes {
            guard let p = point(node.id) else { continue }
            let dim = !lit.isEmpty && !lit.contains(node.id)
            NSGraphicsContext.saveGraphicsState()
            if dim { NSGraphicsContext.current?.cgContext.setAlpha(Metrics.paneDim / 2) }
            mark(node, at: p)
            label(node, at: p)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func mark(_ node: MapNode, at p: CGPoint) {
        let r = Metrics.gapTight
        func ring(_ radius: CGFloat, dashed: Bool = false) -> NSBezierPath {
            let path = NSBezierPath(
                ovalIn: NSRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius))
            path.lineWidth = 1.4
            if dashed { path.setLineDash([2, 1.5], count: 2, phase: 0) }
            NSColor.textBackgroundColor.setFill()
            path.fill()
            NSColor.secondaryLabelColor.setStroke()
            path.stroke()
            return path
        }
        if flashing.contains(node.id) {
            NSColor.agentEditedFolder.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 2.5 * r, y: p.y - 2.5 * r, width: 5 * r, height: 5 * r)).fill()
        }
        switch node.kind {
        case .agent:
            let s = Metrics.iconMenu
            draw(agentIcon, in: NSRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
        case .group, .folder:
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - r + 0.5, y: p.y - r + 0.5, width: 2 * r - 1, height: 2 * r - 1)).fill()
        case .file:
            if node.edited {
                let s = Metrics.iconSmall
                NSColor.systemBlue.setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s),
                    xRadius: Metrics.lineGap + 0.5, yRadius: Metrics.lineGap + 0.5
                ).fill()
            } else {
                _ = ring(r)
            }
        case .folded:
            _ = ring(r + 1)
            let plus = NSBezierPath()
            plus.move(to: NSPoint(x: p.x - r / 2 - 0.5, y: p.y))
            plus.line(to: NSPoint(x: p.x + r / 2 + 0.5, y: p.y))
            plus.move(to: NSPoint(x: p.x, y: p.y - r / 2 - 0.5))
            plus.line(to: NSPoint(x: p.x, y: p.y + r / 2 + 0.5))
            plus.lineWidth = 1.2
            plus.stroke()
        case .more:
            NSColor.fillSelected.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: p.x - 2 * r, y: p.y - r, width: 4 * r, height: 2 * r), xRadius: r, yRadius: r
            ).fill()
        case .outside:
            _ = ring(r + 0.5, dashed: true)
        }
        if node.id == now { ring2(p, color: .labelColor) }
        if node.id == selected { ring2(p, color: .themeAccent) }
    }

    private func ring2(_ p: CGPoint, color: NSColor) {
        let radius = Metrics.iconSmall - 1
        let path = NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius))
        path.lineWidth = Metrics.lineGap
        color.setStroke()
        path.stroke()
    }

    private func label(_ node: MapNode, at p: CGPoint) {
        guard node.kind != .agent else { return }
        let words = text(node), size = words.size()
        var origin = NSPoint(x: p.x + Metrics.inset - Metrics.gapTight, y: p.y - size.height / 2)
        if [.group, .folder].contains(node.kind) {
            origin = NSPoint(x: p.x - Metrics.gapTight, y: p.y - size.height - Metrics.gapTight)
        }
        NSColor.textBackgroundColor.setFill()
        NSRect(x: origin.x - Metrics.lineGap, y: origin.y, width: size.width + 2 * Metrics.lineGap, height: size.height)
            .fill()
        words.draw(at: origin)
        guard ![.group, .folder].contains(node.kind) else { return }
        var x = origin.x + size.width + Metrics.gap
        if let worktree = node.place?.worktree {
            let badge = badgeText(worktree), bs = badge.size()
            let box = NSRect(
                x: x, y: p.y - bs.height / 2 - 1, width: bs.width + 2 * Metrics.gapTight, height: bs.height + 2)
            NSColor.fillSelected.setFill()
            NSBezierPath(roundedRect: box, xRadius: Metrics.radiusXS, yRadius: Metrics.radiusXS).fill()
            badge.draw(at: NSPoint(x: box.minX + Metrics.gapTight, y: box.minY + 1))
            x = box.maxX + Metrics.gap
        }
        let s = Metrics.iconSmall
        for mark in AgentMarks.of(node.agents, agents: agents) {
            switch mark {
            case .agent(let index):
                draw(
                    icons.indices.contains(index) ? icons[index] : nil,
                    in: NSRect(x: x, y: p.y - s / 2, width: s, height: s))
                x += s + Metrics.lineGap
            case .subagents(let list):
                draw(WorkModel.subagentMark(s), in: NSRect(x: x, y: p.y - s / 2, width: s, height: s))
                x += s + Metrics.lineGap
                if list.count > 1 {
                    let count = NSAttributedString(
                        string: "×\(list.count)",
                        attributes: [.font: caption, .foregroundColor: NSColor.secondaryLabelColor])
                    count.draw(at: NSPoint(x: x, y: p.y - count.size().height / 2))
                    x += count.size().width + Metrics.lineGap
                }
            }
        }
    }

    /// Draws an image the right way up in this flipped view, at its full sharpness.
    private func draw(_ image: NSImage?, in rect: NSRect) {
        image?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: Pointer, keys, VoiceOver

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    private func node(at point: NSPoint) -> MapNode? {
        hits.last { $0.rect.contains(point) }.flatMap { hit in nodes.first { $0.id == hit.id } }
    }

    override func mouseMoved(with event: NSEvent) { hover(node(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { hover(nil) }

    private func hover(_ node: MapNode?) {
        guard node?.id != hovered else { return }
        hovered = node?.id
        lit = []
        var id = node?.id
        while let current = id {
            lit.insert(current)
            id = nodes.first { $0.id == current }?.parent
        }
        onHover(node, node.flatMap { n in hits.first { $0.id == n.id }?.rect } ?? .zero)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let hit = node(at: convert(event.locationInWindow, from: nil)) else { return }
        selected = hit.id
        onActivate(hit)
    }

    override func keyDown(with event: NSEvent) {
        let current = nodes.first { $0.id == selected } ?? nodes.first
        guard let current else { return super.keyDown(with: event) }
        let siblings = nodes.filter { $0.parent == current.parent }
        let index = siblings.firstIndex { $0.id == current.id } ?? 0
        switch event.specialKey {
        case .leftArrow?: selected = current.parent ?? current.id
        case .rightArrow?: selected = nodes.first { $0.parent == current.id }?.id ?? current.id
        case .upArrow?: selected = siblings[max(0, index - 1)].id
        case .downArrow?: selected = siblings[min(siblings.count - 1, index + 1)].id
        case .carriageReturn?, .enter?: onActivate(current)
        default:
            if event.charactersIgnoringModifiers == " " {
                onHover(current, hits.first { $0.id == current.id }?.rect ?? .zero)
            } else {
                super.keyDown(with: event)
            }
            return
        }
        if let rect = hits.first(where: { $0.id == selected })?.rect {
            scrollToVisible(rect.insetBy(dx: -pad, dy: -pad))
        }
    }

    private func element(_ node: MapNode) -> NSAccessibilityElement? {
        guard let rect = hits.first(where: { $0.id == node.id })?.rect else { return nil }
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.button)
        let who = node.agents.compactMap { names.indices.contains($0) ? names[$0] : nil }
        element.setAccessibilityLabel(
            ([node.prefix.map { $0 + node.label } ?? node.label, node.detail] + who).filter { !$0.isEmpty }.joined(
                separator: ", "))
        element.setAccessibilityFrameInParentSpace(rect)
        element.setAccessibilityParent(self)
        return element
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { String(localized: "Map of where the agent worked") }
    override func accessibilityChildren() -> [Any]? { elements }
}
