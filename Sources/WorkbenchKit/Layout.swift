import Foundation

/// Pure split-tree for a tab. UI is rebuilt from it, so it is easy to test and persist.
public indirect enum LayoutNode: Codable, Equatable {
    case pane(String)
    case split(vertical: Bool, children: [LayoutNode])   // vertical = side-by-side

    public var sessions: [String] {
        switch self {
        case .pane(let s): [s]
        case .split(_, let c): c.flatMap(\.sessions)
        }
    }

    public func removing(_ id: String) -> LayoutNode? {
        switch self {
        case .pane(let s): return s == id ? nil : self
        case .split(let v, let c):
            let k = c.compactMap { $0.removing(id) }
            if k.isEmpty { return nil }
            return k.count == 1 ? k[0] : .split(vertical: v, children: k)
        }
    }

    /// Put `new` next to `target`. `vertical` = side-by-side; `before` places it left/top.
    public func inserting(_ new: String, beside target: String, vertical: Bool, before: Bool) -> LayoutNode {
        switch self {
        case .pane(let s):
            guard s == target else { return self }
            let pair: [LayoutNode] = before ? [.pane(new), self] : [self, .pane(new)]
            return .split(vertical: vertical, children: pair)
        case .split(let v, let c):
            if v == vertical, let i = c.firstIndex(of: .pane(target)) {
                var k = c
                k.insert(.pane(new), at: before ? i : i + 1)
                return .split(vertical: v, children: k)
            }
            return .split(
                vertical: v, children: c.map { $0.inserting(new, beside: target, vertical: vertical, before: before) })
        }
    }

    /// One key per split: its children's first panes (where the UI keeps divider positions).
    public var splitKeys: Set<String> {
        guard case .split(_, let c) = self else { return [] }
        return c.reduce(into: [Self.splitKey(c)]) { $0.formUnion($1.splitKeys) }
    }
    public static func splitKey(_ children: [LayoutNode]) -> String {
        children.compactMap(\.sessions.first).joined(separator: ",")
    }
}
