import Foundation

public struct TabRef: Codable, Hashable {
    public var id = UUID().uuidString
    public var uri: String
}

public struct GroupModel: Codable, Equatable {
    public var id = UUID().uuidString
    public var tabs: [TabRef] = []
    public var selected: String?
    public var selectedTab: TabRef? { tabs.first { $0.id == selected } ?? tabs.first }
}

/// One workspace's editor area: groups of tabs arranged by a split tree (LayoutNode panes are group ids).
/// Persisted per workspace (by the app) so a relaunch shows the same arrangement.
public struct WorkspaceLayout: Codable, Equatable {
    public var root: LayoutNode?
    public var groups: [String: GroupModel] = [:]
    public var focused: String?
    /// Divider positions the user dragged: each split's shares, keyed by its children's first group ids.
    public var sizes: [String: [Double]]?
    /// The panes are the user's (split or dragged by hand, or agents switched to tabs): agents aren't put side by side.
    public var manual: Bool?

    public init() {}

    public var allTabs: [TabRef] { (root?.sessions ?? []).compactMap { groups[$0] }.flatMap(\.tabs) }
    public var focusedGroup: GroupModel? { focused.flatMap { groups[$0] } ?? root?.sessions.first.flatMap { groups[$0] } }
    /// The tabs being looked at, not merely on screen: among several panes the focused one's, else the one pane's.
    public func attendedTabs(zoomed: String?) -> [TabRef] {
        let panes = zoomed.map { [$0] } ?? root?.sessions ?? []
        return (panes.count > 1 ? [focusedGroup?.id].compactMap { $0 } : panes).compactMap { groups[$0]?.selectedTab }
    }
    public func group(of tab: String) -> String? { groups.first { $0.value.tabs.contains { $0.id == tab } }?.key }
    public func tab(uri: String) -> TabRef? { allTabs.first { $0.uri == uri } }

    /// `new` in the tab that showed `old`, in its place (a restarted session, a file saved under a new name); nil when
    /// no tab shows `old`. A tab `new` already has (the daemon's event for a restarted session can come before the
    /// restart's answer) goes: one tab per URI.
    @discardableResult
    public mutating func replace(_ old: String, with new: String) -> TabRef? {
        guard let t = tab(uri: old) else { return nil }
        if let dup = tab(uri: new) { remove(dup.id) }
        guard let gid = group(of: t.id), let i = groups[gid]?.tabs.firstIndex(of: t) else { return nil }
        groups[gid]?.tabs[i].uri = new
        return t
    }

    /// Adds a tab to `group` (or the focused group, or a new one) and selects it; with `select` false it waits behind
    /// what's shown (nothing moves for a session someone else started).
    @discardableResult
    public mutating func add(_ uri: String, to group: String? = nil, at index: Int? = nil, select: Bool = true) -> TabRef {
        let t = TabRef(uri: uri)
        let gid = group ?? focusedGroup?.id ?? newGroup(beside: nil, vertical: true)
        guard var g = groups[gid] else { return t }
        g.tabs.insert(t, at: min(index ?? g.tabs.count, g.tabs.count))
        if select || g.selected == nil { g.selected = t.id }
        groups[gid] = g
        if select { focused = gid }
        return t
    }

    /// A new empty group next to `beside` (the right / below), or the first one.
    @discardableResult
    public mutating func newGroup(beside: String?, vertical: Bool, before: Bool = false) -> String {
        let g = GroupModel()
        groups[g.id] = g
        if let beside, let r = root { root = r.inserting(g.id, beside: beside, vertical: vertical, before: before) } else if let r = root {
            root = r.inserting(g.id, beside: r.sessions.last ?? g.id, vertical: vertical, before: false)
        } else { root = .pane(g.id) }
        focused = g.id
        return g.id
    }

    public mutating func select(_ tab: String) {
        guard let gid = group(of: tab) else { return }
        groups[gid]?.selected = tab; focused = gid
    }

    /// Removes a tab; an emptied group disappears unless it's the last one.
    public mutating func remove(_ tab: String) {
        guard let gid = group(of: tab), var g = groups[gid], let i = g.tabs.firstIndex(where: { $0.id == tab }) else { return }
        g.tabs.remove(at: i)
        if g.selected == tab { g.selected = g.tabs.isEmpty ? nil : g.tabs[min(i, g.tabs.count - 1)].id }
        groups[gid] = g
        if g.tabs.isEmpty, (root?.sessions.count ?? 0) > 1 { dropGroup(gid) }
    }

    mutating func dropGroup(_ gid: String) {
        groups[gid] = nil
        root = root?.removing(gid)
        if focused == gid { focused = root?.sessions.first }
    }

    /// Moves a tab into another group (index nil = end), or into a new group split off `target` (edge).
    /// `index` is a gap between the target's tabs as they are now, the moved tab included (where the drop bar shows).
    public mutating func move(_ tab: String, to target: String, index: Int? = nil) {
        guard let from = group(of: tab), let t = groups[from]?.tabs.first(where: { $0.id == tab }) else { return }
        if from == target, var g = groups[from], let i = g.tabs.firstIndex(of: t) {
            g.tabs.remove(at: i)
            let at = index.map { $0 > i ? $0 - 1 : $0 } ?? g.tabs.count   // the gaps after it moved left by one
            g.tabs.insert(t, at: min(at, g.tabs.count)); g.selected = t.id
            groups[from] = g; focused = from; return
        }
        guard groups[target] != nil else { return }   // a stale drop target: the tab stays where it was
        remove(tab)
        guard var g = groups[target] else { return }
        g.tabs.insert(t, at: min(index ?? g.tabs.count, g.tabs.count)); g.selected = t.id
        groups[target] = g; focused = target
    }

    /// The tab in a new group along a whole side of the editor area (dropped at its outer edge): full height or width.
    public mutating func splitRoot(_ tab: String, vertical: Bool, before: Bool) {
        guard let t = allTabs.first(where: { $0.id == tab }), let r = root, r.sessions.count > 1 || groups[r.sessions[0]]?.tabs.count ?? 0 > 1 else { return }
        remove(tab)
        let g = GroupModel(); groups[g.id] = g
        groups[g.id]?.tabs = [t]; groups[g.id]?.selected = t.id
        let kids: [LayoutNode]
        if case .split(let v, let c) = root ?? r, v == vertical { kids = before ? [.pane(g.id)] + c : c + [.pane(g.id)] }
        else { kids = before ? [.pane(g.id), root ?? r] : [root ?? r, .pane(g.id)] }
        root = .split(vertical: vertical, children: kids); focused = g.id
    }

    public mutating func split(_ tab: String, from target: String, vertical: Bool, before: Bool) {
        guard let t = allTabs.first(where: { $0.id == tab }) else { return }
        let alone = group(of: tab) == target && groups[target]?.tabs.count == 1
        guard !alone else { return }   // splitting a group off itself with its only tab changes nothing
        remove(tab)
        let gid = newGroup(beside: groups[target] == nil ? nil : target, vertical: vertical, before: before)
        groups[gid]?.tabs = [t]; groups[gid]?.selected = t.id
    }
}
