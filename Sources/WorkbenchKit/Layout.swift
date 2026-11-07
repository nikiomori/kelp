import Foundation

/// Pure split-tree for a tab. UI is rebuilt from it, so it is easy to test and persist.
public indirect enum LayoutNode: Codable, Equatable {
    case pane(String)
    case split(vertical: Bool, children: [LayoutNode])   // vertical = side-by-side

    public var sessions: [String] {
        switch self {
        case .pane(let session): [session]
        case .split(_, let children): children.flatMap(\.sessions)
        }
    }

    public func removing(_ id: String) -> LayoutNode? {
        switch self {
        case .pane(let session): return session == id ? nil : self
        case .split(let vertical, let children):
            let kept = children.compactMap { $0.removing(id) }
            if kept.isEmpty { return nil }
            return kept.count == 1 ? kept[0] : .split(vertical: vertical, children: kept)
        }
    }

    /// Put `new` next to `target`. `vertical` = side-by-side; `before` places it left/top.
    public func inserting(_ new: String, beside target: String, vertical: Bool, before: Bool) -> LayoutNode {
        switch self {
        case .pane(let session):
            guard session == target else { return self }
            let pair: [LayoutNode] = before ? [.pane(new), self] : [self, .pane(new)]
            return .split(vertical: vertical, children: pair)
        case .split(let splitVertical, let children):
            if splitVertical == vertical, let index = children.firstIndex(of: .pane(target)) {
                var newChildren = children
                newChildren.insert(.pane(new), at: before ? index : index + 1)
                return .split(vertical: splitVertical, children: newChildren)
            }
            return .split(
                vertical: splitVertical,
                children: children.map { $0.inserting(new, beside: target, vertical: vertical, before: before) })
        }
    }

    /// One key per split: its children's first panes (where the UI keeps divider positions).
    public var splitKeys: Set<String> {
        guard case .split(_, let children) = self else { return [] }
        return children.reduce(into: [Self.splitKey(children)]) { $0.formUnion($1.splitKeys) }
    }
    public static func splitKey(_ children: [LayoutNode]) -> String {
        children.compactMap(\.sessions.first).joined(separator: ",")
    }
}
